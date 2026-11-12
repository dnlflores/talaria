import Foundation
import Testing

@testable import HermesKit

/// Tests against a real gate. They are skipped unless the environment names one:
///
///   TALARIA_LIVE_BASE=http://127.0.0.1:4300 swift test --filter Live
///
/// - `TALARIA_LIVE_PROFILE` (default `default`): profile used for the session and turn tests.
/// - `TALARIA_LIVE_TURN=1`: also run one real turn (costs a model call, leaves one archived chat).
/// - `TALARIA_GATE_BASE` + `TALARIA_GATE_PASSWORD`: a password-protected listener to sign in to.
private enum Live {
  static let environment = ProcessInfo.processInfo.environment
  static var base: ServerEndpoint? { environment["TALARIA_LIVE_BASE"].flatMap(ServerEndpoint.init(userInput:)) }
  static var profile: String { environment["TALARIA_LIVE_PROFILE"] ?? "default" }
  static var turnEnabled: Bool { base != nil && environment["TALARIA_LIVE_TURN"] == "1" }
  static var gate: ServerEndpoint? { environment["TALARIA_GATE_BASE"].flatMap(ServerEndpoint.init(userInput:)) }
  static var gatePassword: String? { environment["TALARIA_GATE_PASSWORD"] }
}

@Suite(.serialized) struct LiveGatewayTests {
  @Test(.enabled(if: Live.base != nil))
  func gateAnswersAndListsConversations() async throws {
    let client = HermesClient(endpoint: try #require(Live.base), cookies: InMemoryCookieStore())
    guard case .open(let health) = try await client.http.probe() else {
      Issue.record("expected an open gate")
      return
    }
    #expect(health.backendIsRunning)
    #expect(!health.home.isEmpty)
    let sessions = try await client.sessions(recents: 5, messaging: 3, cron: 3)
    for session in sessions {
      #expect(!session.id.isEmpty)
      #expect(!session.profile.isEmpty)
    }
    _ = try await client.owners()
  }

  @Test(.enabled(if: Live.base != nil))
  func socketReachesReadyAndAnswersCalls() async throws {
    let client = HermesClient(endpoint: try #require(Live.base), cookies: InMemoryCookieStore())
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    #expect(await client.rpc.state == .open)

    let profiles = try await client.profiles()
    #expect(profiles.contains { $0.name == Live.profile })

    do {
      _ = try await client.rpc.call("no.such.method", [:], timeout: 15)
      Issue.record("an unknown method should fail")
    } catch let error as HermesError {
      guard case .rpc(let code, _, _) = error else {
        Issue.record("unexpected error \(error)")
        return
      }
      #expect(code == -32601)
    }
    await client.rpc.stop()
    #expect(await client.rpc.state == .idle)
  }

  @Test(.enabled(if: Live.base != nil))
  func aNewSessionReportsItsModelAndCatalog() async throws {
    let client = HermesClient(endpoint: try #require(Live.base), cookies: InMemoryCookieStore())
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    // No prompt is sent, so no stored conversation is left behind.
    let session = try await client.create(profile: Live.profile)
    #expect(!session.liveID.isEmpty)
    #expect(!session.storedID.isEmpty)
    var info = SessionInfo()
    info.merge(session.info)
    #expect(!info.model.isEmpty)

    let catalog = try await client.modelCatalog(liveID: session.liveID, profile: Live.profile)
    #expect(catalog.contains { $0.isAuthenticated && !$0.models.isEmpty })

    try await client.close(liveID: session.liveID)
    await client.rpc.stop()
  }

  @Test(.enabled(if: Live.turnEnabled), .timeLimit(.minutes(3)))
  func aRealTurnStreamsIntoTheTranscript() async throws {
    let client = HermesClient(endpoint: try #require(Live.base), cookies: InMemoryCookieStore())
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    let session = try await client.create(profile: Live.profile, options: NewSessionOptions(title: "Talaria live test"))

    var state = ChatState()
    state.items.append(TranscriptItem(kind: .user, text: "ping", timestamp: Date().timeIntervalSince1970))
    let prompt = "Reply with exactly the word pong and nothing else. Do not use any tools."
    try await client.submit(liveID: session.liveID, profile: Live.profile, text: prompt)

    var seen: [String] = []
    var finished = false
    for await incoming in client.rpc.incoming {
      guard case .event(let event) = incoming, event.sessionID == session.liveID else { continue }
      seen.append(event.type)
      let effects = state.apply(event: event.type, payload: event.payload, now: Date().timeIntervalSince1970)
      if effects.contains(.turnFinished) {
        finished = true
        break
      }
      if case .failure(let message)? = effects.first {
        Issue.record("turn failed: \(message)")
        break
      }
    }
    #expect(finished)
    #expect(seen.contains("message.complete"))
    let answer = state.items.last { $0.kind == .assistant }
    #expect(answer?.text.lowercased().contains("pong") == true)
    #expect(answer?.isStreaming == false)
    #expect(!state.isStreaming)

    // The stored transcript must agree with what was streamed.
    let stored = TranscriptItem.items(fromStoredRows: try await client.storedMessages(storedID: session.storedID, profile: Live.profile))
    #expect(stored.contains { $0.kind == .user && $0.text == prompt })
    #expect(stored.contains { $0.kind == .assistant && $0.text.lowercased().contains("pong") })

    // Resuming returns the same conversation through the other transcript shape.
    let resumed = try await client.resume(storedID: session.storedID, profile: Live.profile)
    let history = TranscriptItem.items(fromHistory: resumed.messages)
    #expect(history.filter { $0.kind == .user }.count == 1)
    #expect(history.last?.kind == .assistant)

    try? await client.close(liveID: resumed.liveID)
    try await client.setArchived(storedID: session.storedID, profile: Live.profile, archived: true)
    await client.rpc.stop()
  }

  @Test(.enabled(if: Live.gate != nil && Live.gatePassword != nil))
  func passwordGateSignsInAndCarriesTheSocket() async throws {
    let endpoint = try #require(Live.gate)
    let password = try #require(Live.gatePassword)
    let cookies = InMemoryCookieStore()
    let client = HermesClient(endpoint: endpoint, cookies: cookies)

    #expect(try await client.http.probe() == .loginRequired)
    await #expect(throws: HermesError.loginRequired) { try await client.sessions(recents: 1, messaging: 1, cron: 1) }

    // Without a session the socket is refused and the connection stops retrying.
    await client.rpc.start()
    await #expect(throws: HermesError.loginRequired) { try await client.rpc.waitUntilReady(timeout: 20) }
    #expect(await client.rpc.state == .unauthorized)

    await #expect(throws: HermesError.wrongPassword) { try await client.http.login(password: password + "-wrong") }
    #expect(cookies.cookie(for: endpoint) == nil)

    try await client.http.login(password: password)
    #expect(cookies.cookie(for: endpoint) != nil)
    guard case .open = try await client.http.probe() else {
      Issue.record("expected the gate to open after signing in")
      return
    }
    _ = try await client.sessions(recents: 1, messaging: 1, cron: 1)

    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    #expect(!(try await client.profiles()).isEmpty)
    await client.rpc.stop()

    await client.http.logout()
    #expect(try await client.http.probe() == .loginRequired)
  }
}
