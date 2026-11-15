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

  // MARK: Coming back to what was not sent

  /// The chat opened again as the app opens it from the list: a new model for the same stored chat.
  private func reopen(_ app: AppModel, _ chat: ChatModel) async -> ChatModel {
    let reopened = ChatModel(app: app, profile: "preview", storedID: chat.storedID, row: nil, live: nil)
    await reopened.open()
    XCTAssertFalse(reopened.isLoading)
    return reopened
  }

  /// Waits until `condition` holds, up to five seconds.
  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<250 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  private func addNotes(_ chat: ChatModel) {
    chat.addFile(data: Data("notes".utf8), name: "notes.txt", mimeType: "text/plain")
  }

  /// Queues `/usage` then words while the reply runs, and leaves before either has gone out.
  private func leaveWithACommandAndWordsQueued(_ name: String) async throws -> (AppModel, ChatModel) {
    let (app, chat) = try await openChat(name, running: true)
    chat.draft = "/usage"
    await chat.send()
    chat.draft = "Implement the fix"
    await chat.send()
    chat.leave()
    let parked = await eventually { app.preferences.queued(for: chat.storedID).count == 2 }
    XCTAssertTrue(parked, "both entries were kept for the next copy")
    XCTAssertTrue(fixture.submitted.isEmpty)
    XCTAssertTrue(fixture.slashRequests.isEmpty, "the command waits for the phone; the Mac's queue takes words only")
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "", "nothing was joined into the draft")
    return (app, chat)
  }

  func testAQueuedCommandAndTheWordsAfterItComeBackAsTwoMessages() async throws {
    let (app, chat) = try await leaveWithACommandAndWordsQueued("boundaries")
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["/usage", "Implement the fix"])
    XCTAssertEqual(reopened.draft, "")
    XCTAssertFalse(reopened.queue.isPaused, "the reply is still running: they wait for it as before")
    reopened.handle(GatewayEvent(type: "message.complete", sessionID: reopened.liveID ?? "", payload: ["text": "Done"]))
    let prompts = await waitForPrompts(1)
    XCTAssertEqual(fixture.slashRequests, ["usage"], "the command ran on its own, without the words after it")
    XCTAssertEqual(prompts.map(\.text), ["Implement the fix"])
    XCTAssertTrue(reopened.state.items.contains { $0.isLocal && $0.text == "ok" }, "the command's answer shows")
    XCTAssertTrue(reopened.queue.isEmpty)
  }

  func testAQueueTakenBackIntoAnIdleChatIsHeldUntilResumed() async throws {
    let (app, chat) = try await leaveWithACommandAndWordsQueued("held")
    fixture.finishesRunning(chat.storedID)
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["/usage", "Implement the fix"])
    XCTAssertTrue(reopened.queue.isPaused, "nothing goes out on its own when the chat opens idle")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(fixture.slashRequests.isEmpty)
    XCTAssertTrue(fixture.submitted.isEmpty)
    reopened.resumeQueue()
    let prompts = await waitForPrompts(1)
    XCTAssertEqual(fixture.slashRequests, ["usage"])
    XCTAssertEqual(prompts.map(\.text), ["Implement the fix"])
  }

  func testAFailedCommandAfterLeavingComesBackWithItsFile() async throws {
    fixture.answerExec { _ in .error(code: 5030, message: "worker unavailable") }
    let (app, chat) = try await openChat("failed-file")
    addNotes(chat)
    fixture.hold()
    chat.draft = "/work A"
    let sending = Task { await chat.send() }
    await waitForSlash()
    chat.leave()
    fixture.release()
    await sending.value
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "/work A")
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.draft, "/work A")
    XCTAssertEqual(reopened.attachments.map(\.name), ["notes.txt"], "the file comes back with the command")
    XCTAssertTrue(fixture.submitted.isEmpty)
  }

  func testPrefillAfterLeavingComesBackWithItsFile() async throws {
    fixture.answerExec { _ in .result(["type": "prefill", "message": "edit me"]) }
    let (app, chat) = try await openChat("prefill-file")
    addNotes(chat)
    fixture.hold()
    chat.draft = "/undo"
    let sending = Task { await chat.send() }
    await waitForSlash()
    chat.leave()
    fixture.release()
    await sending.value
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.draft, "edit me")
    XCTAssertEqual(reopened.attachments.map(\.name), ["notes.txt"])
    XCTAssertTrue(fixture.submitted.isEmpty)
  }

  func testAQueuedCommandThatFailsAfterLeavingKeepsItsPlaceAndFile() async throws {
    fixture.answerExec { _ in .error(code: 5030, message: "worker unavailable") }
    let (app, chat) = try await openChat("failed-queued", running: true)
    addNotes(chat)
    chat.draft = "/work A"
    await chat.send()
    chat.draft = "B"
    await chat.send()
    fixture.hold()
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? "", payload: ["text": "Done"]))
    await waitForSlash()
    chat.leave()
    fixture.release()
    let parked = await eventually { app.preferences.queued(for: chat.storedID).count == 2 }
    XCTAssertTrue(parked)
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["/work A", "B"], "the command keeps its place ahead of B")
    XCTAssertEqual(reopened.queue.entries.first?.attachments.map(\.name), ["notes.txt"])
    XCTAssertTrue(reopened.queue.isPaused, "a failed entry is held, as when the chat stays open")
    XCTAssertEqual(reopened.draft, "")
    XCTAssertTrue(fixture.submitted.isEmpty)
  }

  func testAMessageThatFailsToSendAfterLeavingComesBackWithItsFile() async throws {
    fixture.answerSubmit { _ in .error(code: 5000, message: "boom") }
    let (app, chat) = try await openChat("submit-failed")
    addNotes(chat)
    fixture.holdSubmits()
    chat.draft = "Ship it"
    let sending = Task { await chat.send() }
    let fixture = fixture!
    _ = await fixture.wait { fixture.submitAttempts >= 1 }
    chat.leave()
    fixture.release()
    await sending.value
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.draft, "Ship it")
    XCTAssertEqual(reopened.attachments.map(\.name), ["notes.txt"])
  }

  func testAQueuedMessageThatFailsToSendAfterLeavingComesBackHeldWithItsFile() async throws {
    fixture.answerSubmit { _ in .error(code: 5000, message: "boom") }
    let (app, chat) = try await openChat("submit-failed-queued", running: true)
    addNotes(chat)
    chat.draft = "Ship it"
    await chat.send()
    fixture.holdSubmits()
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? "", payload: ["text": "Done"]))
    let fixture = fixture!
    _ = await fixture.wait { fixture.submitAttempts >= 1 }
    chat.leave()
    fixture.release()
    let parked = await eventually { app.preferences.queued(for: chat.storedID) == ["Ship it"] }
    XCTAssertTrue(parked)
    let reopened = await reopen(app, chat)
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["Ship it"])
    XCTAssertEqual(reopened.queue.entries.first?.attachments.map(\.name), ["notes.txt"])
    XCTAssertTrue(reopened.queue.isPaused)
  }

  func testWhatFailsAfterTheChatWasOpenedAgainGoesToTheOpenCopy() async throws {
    fixture.answerExec { _ in .error(code: 5030, message: "worker unavailable") }
    let (app, chat) = try await openChat("reopened-first")
    addNotes(chat)
    fixture.hold()
    chat.draft = "/work A"
    let sending = Task { await chat.send() }
    await waitForSlash()
    chat.leave()
    // Opened again, as the app does from the list, before the command has answered.
    let reopened = app.chat(profile: "preview", storedID: chat.storedID)
    await reopened.open()
    reopened.draft = "and more"
    fixture.release()
    await sending.value
    XCTAssertEqual(reopened.draft, "/work A\n\nand more", "the command comes back ahead of what was typed since")
    XCTAssertEqual(reopened.attachments.map(\.name), ["notes.txt"])
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "/work A\n\nand more")
  }
}
