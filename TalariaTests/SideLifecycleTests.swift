import HermesKit
import XCTest

@testable import Talaria

/// `/btw` and `/bg` answers through the app's real event pump (`AppModel` signed in, so its pump
/// runs), the production `ChatModel` and `HermesClient`, against the loopback `GatewayFixture`:
/// answers that land while the chat is not on screen, chats that reopen read-only or watched,
/// and an answer that beats its task id.
@MainActor
final class SideLifecycleTests: XCTestCase {
  private var fixture: GatewayFixture!
  private var app: AppModel!
  private var savedAddress = ""

  override func setUp() async throws {
    // Stopping at the first failure unwinds through the async test and hangs it; keep going instead.
    continueAfterFailure = true
    fixture = GatewayFixture()
    fixture.opensWithoutSignIn()
    try await fixture.start()
    app = AppModel()
    savedAddress = app.preferences.serverAddress
    try await app.connect(to: fixture.address)
    try await app.client?.rpc.waitUntilReady(timeout: 10)
  }

  override func tearDown() async throws {
    await app.client?.rpc.stop()
    app.wentToBackground()
    // `connect` remembers the address; the app's next launch must not look for this fixture.
    app.preferences.serverAddress = savedAddress
    fixture.stop()
  }

  /// A chat the fixture holds, opened on screen as the app opens a new one.
  private func openChat(running: Bool = false) async throws -> ChatModel {
    let session = "side-\(UUID().uuidString.prefix(8))"
    if running { fixture.startsRunning(session) }
    let client = try XCTUnwrap(app.client)
    let live = try await client.create(profile: "preview", options: NewSessionOptions(title: session))
    let chat = ChatModel(app: app, profile: "preview", storedID: live.storedID, row: nil, live: live)
    app.chatAppeared(chat)
    await chat.open()
    XCTAssertFalse(chat.isLoading)
    XCTAssertEqual(chat.isStreaming, running)
    return chat
  }

  private func reopen(_ chat: ChatModel) async -> ChatModel {
    let again = app.chat(profile: chat.profile, storedID: chat.storedID)
    XCTAssertFalse(again === chat, "a new copy, as when the chat is opened again")
    app.chatAppeared(again)
    await again.open()
    return again
  }

  private func answers(_ items: [TranscriptItem]) -> [TranscriptItem] { items.filter(\.isSideAnswer) }
  private func held(_ chat: ChatModel) -> [TranscriptItem] { app.sideItems(profile: chat.profile, storedID: chat.storedID) }

  private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// Settle time for a second copy of an event, if one were coming.
  private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

  func testAnOpenChatShowsOneCardAndTheReplyGoesOn() async throws {
    let chat = try await openChat(running: true)
    chat.draft = "/bg tidy notes"
    await chat.send()
    XCTAssertTrue(chat.queue.isEmpty, "not queued behind the reply")
    let taskID = try XCTUnwrap(chat.state.items.last?.side?.taskID)
    XCTAssertEqual(taskID, "bg_fixture1")
    fixture.emit("background.complete", session: chat.storedID, payload: ["task_id": .string(taskID), "text": "Tidied"])
    fixture.emit("background.complete", session: chat.storedID, payload: ["task_id": .string(taskID), "text": "Tidied"])
    let arrived = await waitFor { !self.answers(chat.state.items).isEmpty }
    XCTAssertTrue(arrived)
    await settle()
    XCTAssertEqual(answers(chat.state.items).map(\.side?.prompt), ["tidy notes"], "one card, headed by the task")
    XCTAssertEqual(answers(held(chat)).count, 1)
    XCTAssertTrue(chat.isStreaming, "the reply is still running")
    XCTAssertFalse(fixture.calls.contains("slash.exec"))
    XCTAssertFalse(fixture.calls.contains("session.interrupt"))
    app.chatDisappeared(chat)
  }

  /// Leaving a chat whose reply runs keeps it followed, so its side answer still reaches the app.
  func testAnAnswerAfterLeavingARunningChatShowsWhenItOpensAgain() async throws {
    let chat = try await openChat(running: true)
    chat.draft = "/bg tidy notes"
    await chat.send()
    let taskID = try XCTUnwrap(chat.state.items.last?.side?.taskID)
    app.chatDisappeared(chat)
    await settle()
    XCTAssertFalse(fixture.calls.contains("session.detach"), "still followed while the reply runs")
    fixture.emit("background.complete", session: chat.storedID, payload: ["task_id": .string(taskID), "text": "Tidied after leaving"])
    fixture.emit("background.complete", session: chat.storedID, payload: ["task_id": .string(taskID), "text": "Tidied after leaving"])
    let kept = await waitFor { !self.answers(self.held(chat)).isEmpty }
    XCTAssertTrue(kept, "the app holds the answer with no chat on screen")
    await settle()
    XCTAssertEqual(answers(held(chat)).map(\.side?.prompt), ["tidy notes"], "once, headed by the task")

    let again = await reopen(chat)
    XCTAssertEqual(answers(again.state.items).map(\.text), ["Tidied after leaving"])
    XCTAssertEqual(answers(again.state.items).first?.side?.prompt, "tidy notes")
    app.chatDisappeared(again)
  }

  func testACardStaysWhenTheChatOpensAgainReadOnly() async throws {
    let chat = try await openChat()
    fixture.emit("btw.complete", session: chat.storedID, payload: ["task_id": "btw_kept", "question": "what file?", "text": "Greeting.swift"])
    let arrived = await waitFor { !self.answers(chat.state.items).isEmpty }
    XCTAssertTrue(arrived)
    app.chatDisappeared(chat)
    fixture.refuseResumes()

    let again = await reopen(chat)
    XCTAssertTrue(again.isReadOnly, "resume failed, history read")
    XCTAssertEqual(answers(again.state.items).map(\.side?.prompt), ["what file?"])
    app.chatDisappeared(again)
  }

  func testACardStaysWhenTheChatOpensAgainRunningElsewhere() async throws {
    let chat = try await openChat()
    fixture.emit("btw.complete", session: chat.storedID, payload: ["task_id": "btw_kept", "question": "what file?", "text": "Greeting.swift"])
    let arrived = await waitFor { !self.answers(chat.state.items).isEmpty }
    XCTAssertTrue(arrived)
    app.chatDisappeared(chat)
    fixture.runsElsewhere(chat.storedID)

    let again = await reopen(chat)
    XCTAssertTrue(again.continuesAsNewVersion, "watched: another process runs it")
    XCTAssertEqual(answers(again.state.items).map(\.side?.prompt), ["what file?"])
    app.chatDisappeared(again)
  }

  /// The gateway starts the side agent before it answers with the task id: a fast failure lands first.
  func testAnAnswerBeforeItsTaskIDKeepsTheTaskHeading() async throws {
    fixture.sideAnswersBeforeTaskID("error: provider refused")
    let chat = try await openChat()
    chat.draft = "/bg tidy notes"
    await chat.send()
    await settle()
    let cards = answers(chat.state.items)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.side?.taskID, "bg_fixture1")
    XCTAssertEqual(cards.first?.side?.isFailed, true)
    XCTAssertEqual(cards.first?.side?.prompt, "tidy notes", "headed by the task once its id arrives")
    XCTAssertEqual(answers(held(chat)).first?.side?.prompt, "tidy notes", "the held copy too")
    XCTAssertEqual(held(chat).first { !$0.isSideAnswer }?.side?.taskID, "bg_fixture1", "the held notice has its id")

    app.chatDisappeared(chat)
    let again = await reopen(chat)
    XCTAssertEqual(answers(again.state.items).map(\.side?.prompt), ["tidy notes"])
    app.chatDisappeared(again)
  }

  func testATaskIDBeforeItsAnswerKeepsTheTaskHeading() async throws {
    let chat = try await openChat()
    chat.draft = "/bg tidy notes"
    await chat.send()
    let taskID = try XCTUnwrap(chat.state.items.last?.side?.taskID)
    fixture.emit("background.complete", session: chat.storedID, payload: ["task_id": .string(taskID), "text": "error: provider refused"])
    let arrived = await waitFor { !self.answers(chat.state.items).isEmpty }
    XCTAssertTrue(arrived)
    XCTAssertEqual(answers(chat.state.items).first?.side?.prompt, "tidy notes")
    XCTAssertEqual(answers(held(chat)).first?.side?.prompt, "tidy notes")
    app.chatDisappeared(chat)
  }
}
