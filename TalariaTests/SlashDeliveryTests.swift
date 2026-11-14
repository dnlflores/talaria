@testable import HermesKit
import XCTest

@testable import Talaria

/// How the fixture answers `/work A`: the skill, expanded.
private let skillA: GatewayFixture.Answer = .result([
  "type": "skill", "name": "work", "message": "Expanded skill A", "display": "/work A",
])

/// Slash commands through the production `ChatModel` and `HermesClient`, against a loopback
/// stand-in for the gateway (`GatewayFixture`): what reaches the Mac, in what order, and what the
/// chat keeps, when the chat closes or the app sleeps while a command is still being worked out.
@MainActor
final class SlashDeliveryTests: XCTestCase {
  private var fixture: GatewayFixture!
  private var apps: [AppModel] = []
  private var savedAddress = ""

  override func setUp() async throws {
    // Stopping at the first failure unwinds through the async test and hangs it; keep going instead.
    continueAfterFailure = true
    fixture = GatewayFixture()
    try await fixture.start()
    fixture.answerExec { command in command.hasPrefix("work") ? skillA : .result(["output": "ok"]) }
  }

  override func tearDown() async throws {
    for app in apps {
      await app.client?.rpc.stop()
      // `connect` remembers the address; the app's next launch must not look for this fixture.
      app.preferences.serverAddress = savedAddress
    }
    apps = []
    fixture.stop()
  }

  /// A chat the fixture holds, opened as the app opens a new one.
  private func openChat(_ name: String, running: Bool = false) async throws -> (AppModel, ChatModel) {
    let session = "\(name)-\(UUID().uuidString.prefix(8))"
    if running { fixture.startsRunning(session) }
    let app = AppModel()
    savedAddress = app.preferences.serverAddress
    apps.append(app)
    try await app.connect(to: fixture.address)
    let client = try XCTUnwrap(app.client)
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 10)
    let live = try await client.create(profile: "preview", options: NewSessionOptions(title: session))
    let chat = ChatModel(app: app, profile: "preview", storedID: live.storedID, row: nil, live: live)
    await chat.open()
    XCTAssertFalse(chat.isLoading)
    XCTAssertEqual(chat.isStreaming, running)
    return (app, chat)
  }

  private func waitForSlash(_ count: Int = 1) async {
    let fixture = fixture!
    let arrived = await fixture.wait { fixture.slashRequests.count >= count }
    XCTAssertTrue(arrived, "the command reached the Mac")
  }

  private func waitForPrompts(_ count: Int) async -> [GatewayFixture.Prompt] {
    let fixture = fixture!
    _ = await fixture.wait { fixture.submitted.count >= count }
    // Long enough for a second copy, if one were coming.
    try? await Task.sleep(for: .milliseconds(300))
    return fixture.submitted
  }

  private func userBubbles(_ chat: ChatModel) -> [TranscriptItem] {
    chat.state.items.filter { $0.kind == .user }
  }

  // MARK: Leaving while a command is worked out

  func testLeavingWhileASkillLoadsStillSendsItOnce() async throws {
    let (_, chat) = try await openChat("leave")
    fixture.hold()
    chat.draft = "/work A"
    let sending = Task { await chat.send() }
    await waitForSlash()
    chat.leave()
    fixture.release()
    await sending.value
    let prompts = await waitForPrompts(1)
    XCTAssertEqual(prompts.map(\.text), ["Expanded skill A"], "sent once, as the skill")
  }

  func testLeavingWhileAQueuedSkillLoadsKeepsWhatFollowsBehindIt() async throws {
    let (app, chat) = try await openChat("leave-queue", running: true)
    chat.draft = "/work A"
    await chat.send()
    chat.draft = "B"
    await chat.send()
    XCTAssertEqual(chat.queue.entries.map(\.text), ["/work A", "B"])
    fixture.hold()
    // The reply ends: the command at the front leaves the queue and is worked out.
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? "", payload: ["text": "Done"]))
    await waitForSlash()
    chat.leave()
    fixture.release()
    let prompts = await waitForPrompts(2)
    XCTAssertEqual(prompts.map(\.text), ["Expanded skill A", "B"], "the command's turn first, then what was queued after it")
    XCTAssertEqual(prompts.last?.queued, true, "B waits on the Mac for the skill's reply")
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "", "nothing left behind twice")
  }

  func testACommandThatFailsAfterLeavingIsKeptAsTheDraft() async throws {
    fixture.answerExec { _ in .error(code: 5030, message: "slash worker start failed: boom") }
    let (app, chat) = try await openChat("leave-failed")
    fixture.hold()
    chat.draft = "/frobnicate now"
    let sending = Task { await chat.send() }
    await waitForSlash()
    chat.leave()
    fixture.release()
    await sending.value
    let fixture = fixture!
    _ = await fixture.wait { fixture.slashRequests.count >= 2 }
    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(fixture.submitted.isEmpty, "a command is never sent as words")
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "/frobnicate now", "what was typed is not lost")
  }

  // MARK: Handing the queue to the Mac

  func testGoingToSleepWaitsForTheCommandAtTheFront() async throws {
    let (_, chat) = try await openChat("handoff", running: true)
    chat.draft = "/work A"
    await chat.send()
    chat.draft = "B"
    await chat.send()
    fixture.hold()
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? "", payload: ["text": "Done"]))
    await waitForSlash()
    // The app goes to sleep while the skill is still loading.
    let handOff = Task { await chat.handOffQueue() }
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(fixture.submitted.isEmpty, "B must not reach the Mac before the skill ahead of it")
    fixture.release()
    await handOff.value
    let prompts = await waitForPrompts(2)
    XCTAssertEqual(prompts.map(\.text), ["Expanded skill A", "B"])
    XCTAssertEqual(prompts.last?.queued, true)
    XCTAssertEqual(chat.queue.onMac.map(\.text), ["B"], "B shows as waiting on the Mac")
    XCTAssertTrue(chat.queue.entries.isEmpty)
  }

  // MARK: What the bubble shows, and matching the Mac's copy

  func testASkillShowsWhatWasTypedAndIsFoundAgainOnReload() async throws {
    let (_, chat) = try await openChat("skill")
    chat.draft = "/work A"
    await chat.send()
    let prompts = await waitForPrompts(1)
    XCTAssertEqual(prompts.map(\.text), ["Expanded skill A"])
    let bubble = try XCTUnwrap(userBubbles(chat).first)
    XCTAssertEqual(userBubbles(chat).map(\.text), ["/work A"])
    // Re-attaching reads the Mac's stored copy (the expanded skill): it is the same message.
    await chat.connectionReady()
    XCTAssertEqual(userBubbles(chat).map(\.id), [bubble.id], "one bubble, kept, not a second copy")
    XCTAssertEqual(userBubbles(chat).map(\.text), ["/work A"], "still what was typed, never the skill body")
  }

  func testASentMessageWithAFileShowsTheCommandAndIsFoundAgainOnReload() async throws {
    fixture.answerExec { _ in .result(["type": "send", "message": "Ship notes", "notice": "Goal set"]) }
    let (_, chat) = try await openChat("send-file")
    chat.addFile(data: Data("notes".utf8), name: "notes.txt", mimeType: "text/plain")
    chat.draft = "/goal Ship notes"
    await chat.send()
    let prompts = await waitForPrompts(1)
    XCTAssertEqual(prompts.map(\.text), ["Ship notes\n\n@file:/fixture/notes.txt"])
    let bubble = try XCTUnwrap(userBubbles(chat).first)
    XCTAssertEqual(userBubbles(chat).map(\.text), ["/goal Ship notes"], "what was typed, not the composed words")
    XCTAssertTrue(chat.state.items.contains { $0.isLocal && $0.text == "Goal set" })
    await chat.connectionReady()
    XCTAssertEqual(userBubbles(chat).map(\.id), [bubble.id], "matched against the stored copy, file and all")
    XCTAssertEqual(userBubbles(chat).map(\.text), ["/goal Ship notes"])
  }
}
