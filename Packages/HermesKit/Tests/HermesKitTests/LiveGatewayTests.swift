import Foundation
import Testing

@testable import HermesKit

/// Tests against Hermes' own listener on the Mac. They are skipped unless the environment names it:
///
///   TALARIA_LIVE_BASE=https://<mac>.ts.net:10000 TALARIA_LIVE_SIGNIN=<file> swift test --filter Live
///
/// - `TALARIA_LIVE_SIGNIN`: a JSON file holding a sign-in (`access_token`, `refresh_token`,
///   `expires_at`, `provider`), as `scripts/sign-in.py` writes it. Renewed tokens are written back.
///   Leave it out for a listener that needs no sign-in.
/// - `TALARIA_LIVE_PROFILE` (default `default`): profile used for the session and turn tests.
/// - `TALARIA_LIVE_TURN=1`: also run real turns (costs model calls; the chats are archived).
enum Live {
  static let environment = ProcessInfo.processInfo.environment
  static var base: ServerEndpoint? { environment["TALARIA_LIVE_BASE"].flatMap(ServerEndpoint.init(userInput:)) }
  static var profile: String { environment["TALARIA_LIVE_PROFILE"] ?? "default" }
  static var turnEnabled: Bool { base != nil && environment["TALARIA_LIVE_TURN"] == "1" }
  static var signInFile: String? { environment["TALARIA_LIVE_SIGNIN"].flatMap { $0.isEmpty ? nil : $0 } }

  static func client() throws -> HermesClient {
    guard let endpoint = base else { throw HermesError.notConnected }
    let store: any SignInStore = signInFile.map { FileSignInStore(path: $0) } ?? InMemorySignInStore()
    return HermesClient(endpoint: endpoint, signIns: store)
  }
}

@Suite(.serialized) struct LiveGatewayTests {
  @Test(.enabled(if: Live.base != nil))
  func gateAnswersAndListsConversations() async throws {
    let client = try Live.client()
    guard case .open(let health) = try await client.http.probe() else {
      Issue.record("expected an open gate")
      return
    }
    #expect(health.gatewayRunning)
    #expect(!(try await client.macHome()).isEmpty)
    let sessions = try await client.sessions(recents: 5, messaging: 3, cron: 3)
    for session in sessions {
      #expect(!session.id.isEmpty)
      #expect(!session.profile.isEmpty)
    }
    _ = try await client.owners()
  }

  @Test(.enabled(if: Live.base != nil))
  func socketReachesReadyAndAnswersCalls() async throws {
    let client = try Live.client()
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
    let client = try Live.client()
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    // The gateway stores a new chat at once, so it is archived at the end.
    let session = try await client.create(profile: Live.profile)
    #expect(!session.liveID.isEmpty)
    #expect(!session.storedID.isEmpty)
    var info = SessionInfo()
    info.merge(session.info)
    #expect(!info.model.isEmpty)

    let catalog = try await client.modelCatalog(liveID: session.liveID, profile: Live.profile)
    #expect(catalog.contains { $0.isAuthenticated && !$0.models.isEmpty })

    try await client.setArchived(storedID: session.storedID, profile: Live.profile, archived: true)
    try await client.detach(liveID: session.liveID, subscriptionID: session.subscriptionID, profile: Live.profile)
    await client.rpc.stop()
  }

  @Test(.enabled(if: Live.turnEnabled), .timeLimit(.minutes(3)))
  func aRealTurnStreamsIntoTheTranscript() async throws {
    let client = try Live.client()
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    let session = try await client.create(profile: Live.profile, options: NewSessionOptions(title: "Talaria live test \(UUID().uuidString.prefix(8))"))

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

    try? await client.detach(liveID: resumed.liveID, subscriptionID: resumed.subscriptionID, profile: Live.profile)
    try await client.setArchived(storedID: session.storedID, profile: Live.profile, archived: true)
    await client.rpc.stop()
  }

  @Test(.enabled(if: Live.base != nil && Live.signInFile != nil))
  func withoutASignInEverythingIsRefused() async throws {
    let client = HermesClient(endpoint: try #require(Live.base), signIns: InMemorySignInStore())
    #expect(try await client.http.probe() == .loginRequired)
    await #expect(throws: HermesError.loginRequired) { try await client.sessions(recents: 1, messaging: 1, cron: 1) }
    // Without a sign-in the socket is refused and the connection stops retrying.
    await client.rpc.start()
    await #expect(throws: HermesError.loginRequired) { try await client.rpc.waitUntilReady(timeout: 20) }
    #expect(await client.rpc.state == .unauthorized)
  }

  @Test(.enabled(if: Live.base != nil && Live.signInFile != nil))
  func aSignInOpensRESTAndTheSocketAndRenews() async throws {
    let client = try Live.client()
    guard case .open = try await client.http.probe() else {
      Issue.record("expected the sign-in to open Hermes")
      return
    }
    // A token that ran out is renewed with the refresh token, and the request goes through.
    let endpoint = try #require(Live.base)
    let file = try #require(Live.signInFile)
    let held = try #require(FileSignInStore(path: file).signIn(for: endpoint))
    let stale = InMemorySignInStore(
      SignIn(accessToken: "expired-\(UUID().uuidString)", refreshToken: held.refreshToken, expiresAt: nil, provider: held.provider),
      for: endpoint)
    let renewing = HermesClient(endpoint: endpoint, signIns: stale)
    _ = try await renewing.sessions(recents: 1, messaging: 1, cron: 1)
    let renewed = try #require(stale.signIn(for: endpoint))
    #expect(!renewed.accessToken.hasPrefix("expired-"))
    FileSignInStore(path: file).setSignIn(renewed, for: endpoint)

    let fresh = try Live.client()
    await fresh.rpc.start()
    try await fresh.rpc.waitUntilReady(timeout: 30)
    #expect(!(try await fresh.profiles()).isEmpty)
    await fresh.rpc.stop()
  }
}
