@testable import HermesKit
import XCTest

@testable import Talaria

/// Edit through the production `ChatModel` and `HermesClient`, against the loopback stand-in for
/// the gateway (`GatewayFixture`), which rewinds its stored copy the way the gateway does: what the
/// Mac's history holds after an edit, the draft set aside for it, and that nothing is taken back
/// when the chat moved on or a reply started meanwhile.
@MainActor
final class EditDeliveryTests: XCTestCase {
  private var fixture: GatewayFixture!
  private var apps: [AppModel] = []
  private var savedAddress = ""

  override func setUp() async throws {
    continueAfterFailure = true
    fixture = GatewayFixture()
    try await fixture.start()
  }

  override func tearDown() async throws {
    // Answers a test held and never let go.
    fixture.release()
    for app in apps {
      await app.client?.rpc.stop()
      app.preferences.serverAddress = savedAddress
    }
    apps = []
    fixture.stop()
  }

  private func openChat(
    _ name: String, seed: [(role: String, content: JSONValue)] = []
  ) async throws -> (AppModel, ChatModel, String) {
    let session = "\(name)-\(UUID().uuidString.prefix(8))"
    fixture.seed(session, seed)
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
    return (app, chat, session)
  }

  /// A chat already on the Mac, opened from its stored rows (as a chat picked from the inbox is).
  private func openStored(
    _ name: String, seed: [(role: String, content: JSONValue)]
  ) async throws -> (AppModel, ChatModel, String) {
    let (app, created, session) = try await openChat(name, seed: seed)
    created.leave()
    let chat = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await chat.open()
    XCTAssertFalse(chat.isLoading)
    return (app, chat, session)
  }

  private func eventually(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// Sends `question` from the composer and lets the Mac answer it.
  private func ask(_ chat: ChatModel, _ session: String, _ question: String, answer: String) async {
    chat.draft = question
    await chat.send()
    fixture.reply(session, answer)
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? session, payload: ["text": .string(answer)]))
    let shown = await eventually { !chat.isStreaming && chat.state.items.contains { $0.kind == .assistant && $0.text == answer } }
    XCTAssertTrue(shown, "the answer shows")
  }

  private func history(_ session: String) -> [String] {
    fixture.transcript(session).map { "\($0.role): \($0.text)" }
  }

  private func newestMessage(_ chat: ChatModel) throws -> TranscriptItem {
    try XCTUnwrap(chat.state.items.last { $0.kind == .user })
  }

  // MARK: Editing

  func testAnEditReplacesTheNewestTurnAndTheDraftComesBack() async throws {
    let (app, chat, session) = try await openChat("edit")
    await ask(chat, session, "What is two plus too?", answer: "Did you mean two?")
    chat.draft = "Half a thought"
    let message = try newestMessage(chat)
    XCTAssertEqual(chat.editOffers, [message.id], "only the message offers Edit, not the reply")

    chat.beginEdit(message)
    XCTAssertEqual(chat.draft, "What is two plus too?", "the message's words are in the composer")
    XCTAssertNotNil(chat.editing)
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "Half a thought", "the set-aside draft is what the chat keeps")
    chat.draft = "What is two plus two?"
    XCTAssertTrue(chat.canSend)
    XCTAssertFalse(chat.sendQueues)

    await chat.send()
    let sent = await eventually { self.fixture.submitted.count == 2 }
    XCTAssertTrue(sent, "the edited words went out")
    XCTAssertEqual(fixture.submitted.map(\.text), ["What is two plus too?", "What is two plus two?"])
    XCTAssertEqual(fixture.mutateRequests.map(\.operation), ["rewind"], "the old turn came off with the same rewind as Try again")
    XCTAssertEqual(history(session), ["user: What is two plus two?"], "one copy of the new words, nothing of the old turn")
    XCTAssertNil(chat.editing, "the editing bar is gone")
    XCTAssertEqual(chat.draft, "Half a thought", "the draft set aside comes back")

    fixture.reply(session, "Four")
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? session, payload: ["text": "Four"]))
    let settled = await eventually { !chat.isStreaming }
    XCTAssertTrue(settled)
    XCTAssertEqual(history(session), ["user: What is two plus two?", "assistant: Four"])
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user }.map(\.text), ["What is two plus two?"], "one bubble, the new words")
    XCTAssertEqual(chat.state.items.filter { $0.kind == .assistant }.map(\.text), ["Four"], "only the new answer")
  }

  func testAnEditKeepsTheTurnsBeforeIt() async throws {
    let (_, chat, session) = try await openChat("edit-second")
    await ask(chat, session, "First", answer: "One")
    await ask(chat, session, "Secnod", answer: "Two?")
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Second"
    await chat.send()
    let sent = await eventually { self.fixture.submitted.count == 3 }
    XCTAssertTrue(sent)
    XCTAssertEqual(history(session), ["user: First", "assistant: One", "user: Second"])
  }

  func testCancelBringsTheDraftBack() async throws {
    let (app, chat, session) = try await openChat("edit-cancel")
    await ask(chat, session, "Mine", answer: "Answer")
    chat.draft = "Half a thought"
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Mine, changed"
    chat.cancelEdit()
    XCTAssertNil(chat.editing)
    XCTAssertEqual(chat.draft, "Half a thought")
    XCTAssertEqual(app.preferences.draft(for: chat.storedID), "Half a thought")
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "nothing was taken back")
    XCTAssertEqual(history(session), ["user: Mine", "assistant: Answer"])
  }

  // MARK: When the send fails or its answer is lost

  func testAnEditThatFailsToSendAfterTheRewindKeepsBothDrafts() async throws {
    let (_, chat, session) = try await openChat("edit-send-fails")
    await ask(chat, session, "Mine", answer: "Answer")
    chat.draft = "Half a thought"
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Mine, edited"
    fixture.answerSubmit { text in text == "Mine, edited" ? .error(code: 5000, message: "boom") : nil }
    await chat.send()
    XCTAssertEqual(history(session), [], "the old turn came off")
    XCTAssertNil(chat.editing)
    XCTAssertEqual(chat.draft, "Mine, edited\n\nHalf a thought", "the edited words come back, the draft after them")
  }

  func testAnEditWhoseRewindAnswerWasLostGoesOutOnTheNextSend() async throws {
    let (app, chat, session) = try await openChat("edit-lost")
    await ask(chat, session, "First", answer: "One")
    await ask(chat, session, "Secnod", answer: "Two?")
    chat.draft = "Half a thought"
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Second"
    fixture.dropNextMutateAnswer()
    await chat.send()
    XCTAssertEqual(history(session), ["user: First", "assistant: One"], "the rewind landed, its answer was lost")
    XCTAssertEqual(fixture.submitted.count, 2, "so the edit was not sent")
    XCTAssertNotNil(chat.editing, "still editing")
    XCTAssertEqual(chat.draft, "Second")

    try await XCTUnwrap(app.client).rpc.waitUntilReady(timeout: 15)
    await chat.send()
    let sent = await eventually { self.fixture.submitted.count == 3 }
    XCTAssertTrue(sent)
    XCTAssertEqual(Set(fixture.mutateRequests.map(\.requestID)).count, 1, "the same rewind was sent again, not a new one")
    XCTAssertEqual(fixture.submitted.last?.text, "Second")
    XCTAssertEqual(history(session), ["user: First", "assistant: One", "user: Second"], "First was not taken back too")
    XCTAssertNil(chat.editing)
    XCTAssertEqual(chat.draft, "Half a thought")
  }

  // MARK: Nothing taken back

  func testAViewBehindTheMacReplacesNothing() async throws {
    let (app, chat, session) = try await openChat("edit-behind")
    await ask(chat, session, "Mine", answer: "Answer to mine")
    chat.draft = "Half a thought"
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Mine, edited"
    fixture.sendFromAnotherDevice(session, "From the desktop", reply: "Answer to the desktop")
    await chat.send()
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "nothing is rewound")
    XCTAssertEqual(fixture.submitted.map(\.text), ["Mine"], "the edit is not sent")
    XCTAssertEqual(app.toast?.text, ChatModel.editChanged)
    XCTAssertNil(chat.editing)
    XCTAssertEqual(chat.draft, "Mine, edited\n\nHalf a thought", "the edited words stay, the draft after them")
    let reloaded = await eventually { chat.state.items.contains { $0.text == "From the desktop" } }
    XCTAssertTrue(reloaded, "the chat reloads to the Mac's copy")
  }

  func testTheSameWordsSentAgainElsewhereAreStillANewerTurn() async throws {
    let (app, chat, session) = try await openChat("edit-same-words")
    await ask(chat, session, "Check the build", answer: "Original answer")
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Check the tests"
    fixture.sendFromAnotherDevice(session, "Check the build", reply: "New answer from desktop")
    await chat.send()
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "a different row with the same words is not the message being edited")
    XCTAssertEqual(history(session).count, 4)
    XCTAssertEqual(app.toast?.text, ChatModel.editChanged)
    XCTAssertEqual(chat.draft, "Check the tests")
  }

  func testAReplyStartedMeanwhileKeepsTheEditOutOfTheQueue() async throws {
    let (app, chat, session) = try await openChat("edit-busy")
    await ask(chat, session, "Mine", answer: "Answer")
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "Mine, edited"
    // The Mac starts a reply in this chat (a turn from another device or a background task).
    chat.handle(GatewayEvent(type: "message.start", sessionID: chat.liveID ?? session, payload: [:]))
    XCTAssertTrue(chat.isStreaming)
    XCTAssertTrue(chat.editOffers.isEmpty, "no Edit offered while a reply runs")
    XCTAssertTrue(chat.canSend, "the send button sends the edit")
    XCTAssertFalse(chat.sendQueues, "and never queues it")
    XCTAssertFalse(chat.showsStop)
    await chat.send()
    XCTAssertEqual(app.toast?.text, ChatModel.editBusy)
    XCTAssertTrue(chat.queue.entries.isEmpty, "not queued behind the reply")
    XCTAssertTrue(fixture.mutateRequests.isEmpty)
    XCTAssertNotNil(chat.editing, "still editing, to send once the reply ends")
    XCTAssertEqual(chat.draft, "Mine, edited")
  }

  func testACommandIsNotSentAsAnEdit() async throws {
    let (app, chat, session) = try await openChat("edit-command")
    await ask(chat, session, "Mine", answer: "Answer")
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "/usage"
    XCTAssertTrue(chat.slashItems.isEmpty, "no / menu over an edit")
    await chat.send()
    XCTAssertEqual(app.toast?.text, ChatModel.editCommand)
    XCTAssertTrue(fixture.mutateRequests.isEmpty)
    XCTAssertTrue(fixture.slashRequests.isEmpty)
    XCTAssertNotNil(chat.editing)
  }

  func testAPictureMessageOffersNoEdit() async throws {
    let (_, chat, _) = try await openStored("edit-picture", seed: [
      ("user", "@image:/tmp/photo.jpg\n[screenshot]"), ("assistant", "A cat."),
    ])
    XCTAssertFalse(chat.retryOffers.isEmpty, "Try again is offered on the turn")
    XCTAssertTrue(chat.editOffers.isEmpty, "a message with a picture is not edited")
    chat.beginEdit(try newestMessage(chat))
    XCTAssertNil(chat.editing)
  }

  func testAStoredMessageIsEditedByItsRow() async throws {
    let (_, chat, session) = try await openStored("edit-stored", seed: [
      ("user", "A"), ("assistant", "Answer A"), ("user", "B with a typo"), ("assistant", "Answer B"),
    ])
    let message = try newestMessage(chat)
    XCTAssertNotNil(message.rowID, "a message read from stored rows knows its row")
    chat.beginEdit(message)
    chat.draft = "B"
    await chat.send()
    let sent = await eventually { self.fixture.submitted.count == 1 }
    XCTAssertTrue(sent)
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: B"])
  }

  // MARK: After leaving the chat

  /// A stored chat with turns A and B, on screen, with `Half a thought` set aside for an edit of B
  /// to `B edited` whose rewind the Mac has applied but not yet answered.
  private func editInFlight(_ name: String) async throws -> (AppModel, ChatModel, String, Task<Void, Never>) {
    let (app, chat, session) = try await openStored(name, seed: [
      ("user", "A"), ("assistant", "Answer A"), ("user", "B"), ("assistant", "Answer B"),
    ])
    app.chatAppeared(chat)
    chat.draft = "Half a thought"
    chat.beginEdit(try newestMessage(chat))
    chat.draft = "B edited"
    fixture.holdNextMutateAnswer()
    let sending = Task { await chat.send() }
    let applied = await eventually { self.fixture.mutateRequests.count == 1 }
    XCTAssertTrue(applied)
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A"], "the old turn came off; its answer is held")
    return (app, chat, session, sending)
  }

  /// The person leaves the chat and opens it again.
  private func reopen(_ old: ChatModel, in app: AppModel, session: String) async -> ChatModel {
    app.chatDisappeared(old)
    let chat = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await chat.open()
    app.chatAppeared(chat)
    return chat
  }

  func testATryAgainAfterLeavingSendsTheEditNotTheOldWords() async throws {
    let (app, old, session, sending) = try await editInFlight("edit-replayed")
    let chat = await reopen(old, in: app, session: session)
    XCTAssertEqual(chat.draft, "Half a thought", "the reopened chat keeps the draft set aside")
    // Try again replays the rewind the left copy sent, and finishes that edit.
    await chat.retry()
    let sent = await eventually { self.fixture.submitted.count == 1 }
    XCTAssertTrue(sent)
    // The left copy's answer arrives late: it sends nothing more.
    fixture.release()
    await sending.value
    XCTAssertEqual(fixture.submitted.map(\.text), ["B edited"], "the edit went, not the old words")
    XCTAssertEqual(Set(fixture.mutateRequests.map(\.requestID)).count, 1, "one rewind, replayed")
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: B edited"])
    XCTAssertEqual(chat.draft, "Half a thought", "nothing added to the composer")
  }

  func testAnEditRefusedAfterLeavingKeepsItsWordsWithTheDraft() async throws {
    let (app, old, session, sending) = try await editInFlight("edit-refused-reopened")
    let chat = await reopen(old, in: app, session: session)
    XCTAssertEqual(chat.draft, "Half a thought")
    fixture.sendFromAnotherDevice(session, "C", reply: "Answer C")
    fixture.release()
    await sending.value
    XCTAssertTrue(fixture.submitted.isEmpty, "an edit of a chat that moved on is not sent")
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: C", "assistant: Answer C"])
    XCTAssertEqual(chat.draft, "B edited\n\nHalf a thought", "the edit is where the toast says, the draft after it")
    XCTAssertEqual(app.toast?.text, ChatModel.editChanged)
    XCTAssertEqual(app.preferences.draft(for: session), "B edited\n\nHalf a thought")
  }

  func testAnEditRefusedWhileTheChatIsClosedComesBackOnTheNextOpen() async throws {
    let (app, old, session, sending) = try await editInFlight("edit-refused-closed")
    app.chatDisappeared(old)
    fixture.sendFromAnotherDevice(session, "C", reply: "Answer C")
    fixture.release()
    await sending.value
    XCTAssertTrue(fixture.submitted.isEmpty)
    let chat = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await chat.open()
    app.chatAppeared(chat)
    XCTAssertEqual(chat.draft, "B edited\n\nHalf a thought", "kept with the saved draft, though no copy was on screen")
  }
}
