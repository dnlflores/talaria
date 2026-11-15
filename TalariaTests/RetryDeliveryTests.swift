@testable import HermesKit
import XCTest

@testable import Talaria

/// Try again through the production `ChatModel` and `HermesClient`, against the loopback
/// stand-in for the gateway (`GatewayFixture`), which rewinds its stored copy the way the gateway
/// does: what the Mac's history holds afterwards, and that nothing is resent from a stale view or
/// applied twice after a lost answer.
@MainActor
final class RetryDeliveryTests: XCTestCase {
  private var fixture: GatewayFixture!
  private var apps: [AppModel] = []
  private var savedAddress = ""

  override func setUp() async throws {
    continueAfterFailure = true
    fixture = GatewayFixture()
    try await fixture.start()
  }

  override func tearDown() async throws {
    for app in apps {
      await app.client?.rpc.stop()
      app.preferences.serverAddress = savedAddress
    }
    apps = []
    fixture.stop()
  }

  private func openChat(
    _ name: String, running: Bool = false, seed: [(role: String, content: JSONValue)] = []
  ) async throws -> (AppModel, ChatModel, String) {
    let session = "\(name)-\(UUID().uuidString.prefix(8))"
    if running { fixture.startsRunning(session) }
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

  private func notices(_ chat: ChatModel) -> [String] {
    chat.state.items.filter { $0.isLocal }.map(\.text)
  }

  private func history(_ session: String) -> [String] {
    fixture.transcript(session).map { "\($0.role): \($0.text)" }
  }

  // MARK: Trying again

  func testTryAgainLeavesOneCopyOfTheMessageFollowedByANewAnswer() async throws {
    let (_, chat, session) = try await openChat("retry")
    await ask(chat, session, "What is two plus two?", answer: "Five")
    XCTAssertEqual(chat.retryOffers.count, 2, "the message and its reply offer Try again")

    await chat.retry()
    let resent = await eventually { self.fixture.submitted.count == 2 }
    XCTAssertTrue(resent, "the same words went out again")
    XCTAssertEqual(fixture.submitted.map(\.text), ["What is two plus two?", "What is two plus two?"])
    XCTAssertEqual(fixture.mutateRequests.map(\.operation), ["rewind"])
    XCTAssertEqual(history(session), ["user: What is two plus two?"], "the old answer is gone, the message is there once")

    fixture.reply(session, "Four")
    chat.handle(GatewayEvent(type: "message.complete", sessionID: chat.liveID ?? session, payload: ["text": "Four"]))
    XCTAssertEqual(history(session), ["user: What is two plus two?", "assistant: Four"])
    let settled = await eventually { !chat.isStreaming }
    XCTAssertTrue(settled)
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user }.map(\.text), ["What is two plus two?"], "one bubble")
    XCTAssertEqual(chat.state.items.filter { $0.kind == .assistant }.map(\.text), ["Four"], "only the new answer")
  }

  func testSlashRetryDoesTheSame() async throws {
    let (_, chat, session) = try await openChat("retry-slash")
    await ask(chat, session, "First", answer: "One")
    await ask(chat, session, "Second", answer: "Two")
    chat.draft = "/retry"
    await chat.send()
    let resent = await eventually { self.fixture.submitted.count == 3 }
    XCTAssertTrue(resent)
    XCTAssertEqual(fixture.submitted.map(\.text), ["First", "Second", "Second"], "/retry itself is never sent as words")
    XCTAssertEqual(history(session), ["user: First", "assistant: One", "user: Second"])
    XCTAssertTrue(fixture.slashRequests.isEmpty, "/retry does not go to the Mac's slash worker")
  }

  // MARK: Never on a stale view

  func testAViewBehindTheMacTakesNothingBack() async throws {
    let (_, chat, session) = try await openChat("retry-behind")
    await ask(chat, session, "Mine", answer: "Answer to mine")
    fixture.sendFromAnotherDevice(session, "From the desktop", reply: "Answer to the desktop")
    chat.draft = "/retry"
    await chat.send()
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "nothing is rewound")
    XCTAssertEqual(fixture.submitted.map(\.text), ["Mine"], "nothing is resent")
    XCTAssertEqual(notices(chat), [ChatModel.retryChanged])
    let reloaded = await eventually { chat.state.items.contains { $0.text == "From the desktop" } }
    XCTAssertTrue(reloaded, "the chat reloads to the Mac's copy")
  }

  func testAChatThatMovesOnBeforeTheRewindIsNotResent() async throws {
    let (_, chat, session) = try await openChat("retry-race")
    await ask(chat, session, "Mine", answer: "Answer to mine")
    fixture.moveOnBeforeNextMutate()
    chat.draft = "/retry"
    await chat.send()
    XCTAssertEqual(fixture.mutateRequests.count, 1, "refused once, never retried at fresh fences")
    XCTAssertEqual(fixture.submitted.map(\.text), ["Mine"], "nothing is resent")
    XCTAssertEqual(history(session).count, 4, "nothing came off")
    XCTAssertEqual(notices(chat), [ChatModel.retryChanged])
    let reloaded = await eventually { chat.state.items.contains { $0.text == "Sent meanwhile" } }
    XCTAssertTrue(reloaded, "the chat reloads to the Mac's copy")
  }

  func testTheSameWordsSentAgainElsewhereAreStillANewerTurn() async throws {
    let (app, chat, session) = try await openStored("retry-same-words", seed: [
      ("user", "Check the build"), ("assistant", "Original answer"),
    ])
    fixture.sendFromAnotherDevice(session, "Check the build", reply: "New answer from desktop")
    await chat.retry()
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "a different row with the same words is not the turn on screen")
    XCTAssertTrue(fixture.submitted.isEmpty, "nothing is resent")
    XCTAssertEqual(history(session), [
      "user: Check the build", "assistant: Original answer", "user: Check the build", "assistant: New answer from desktop",
    ], "the unseen answer is still there")
    XCTAssertEqual(app.toast?.text, ChatModel.retryChanged)
    XCTAssertTrue(chat.state.items.contains { $0.text == "New answer from desktop" }, "the chat reloads to the Mac's copy")
  }

  func testTheSameWordsSentElsewhereAfterAMessageFromHereAreStillANewerTurn() async throws {
    let (_, chat, session) = try await openChat("retry-same-words-here")
    await ask(chat, session, "Check the build", answer: "Original answer")
    fixture.sendFromAnotherDevice(session, "Check the build", reply: "New answer from desktop")
    chat.draft = "/retry"
    await chat.send()
    XCTAssertTrue(fixture.mutateRequests.isEmpty, "a message sent from here is matched to its own row")
    XCTAssertEqual(fixture.submitted.map(\.text), ["Check the build"], "nothing is resent")
    XCTAssertEqual(history(session).count, 4)
    XCTAssertEqual(notices(chat), [ChatModel.retryChanged])
    XCTAssertTrue(chat.state.items.contains { $0.text == "New answer from desktop" }, "the chat reloads to the Mac's copy")
  }

  // MARK: A lost answer

  func testARewindWhoseAnswerWasLostIsReplayedNotRepeated() async throws {
    let (app, chat, session) = try await openChat("retry-lost")
    await ask(chat, session, "First", answer: "One")
    await ask(chat, session, "Second", answer: "Two")
    fixture.dropNextMutateAnswer()
    await chat.retry()
    XCTAssertEqual(history(session), ["user: First", "assistant: One"], "the rewind landed")
    XCTAssertEqual(fixture.submitted.count, 2, "but its answer was lost, so nothing was resent")

    try await XCTUnwrap(app.client).rpc.waitUntilReady(timeout: 15)
    await chat.retry()
    let resent = await eventually { self.fixture.submitted.count == 3 }
    XCTAssertTrue(resent)
    let mutations = fixture.mutateRequests
    XCTAssertEqual(mutations.count, 2)
    XCTAssertEqual(Set(mutations.map(\.requestID)).count, 1, "the second try sent the same request again")
    XCTAssertEqual(fixture.submitted.last?.text, "Second", "the turn that was taken back goes out")
    XCTAssertEqual(history(session), ["user: First", "assistant: One", "user: Second"], "First was not taken back too")
  }

  func testAnOldReceiptIsNotResentAfterAnotherDeviceMovesOn() async throws {
    let (app, chat, session) = try await openStored("retry-lost-moved-on", seed: [
      ("user", "A"), ("assistant", "Answer A"), ("user", "B"), ("assistant", "Answer B"),
    ])
    fixture.dropNextMutateAnswer()
    await chat.retry()
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A"], "the rewind landed, its answer was lost")
    XCTAssertTrue(fixture.submitted.isEmpty)

    fixture.sendFromAnotherDevice(session, "C", reply: "Answer C")
    try await XCTUnwrap(app.client).rpc.waitUntilReady(timeout: 15)
    await chat.connectionReady()
    XCTAssertTrue(chat.state.items.contains { $0.text == "C" })
    await chat.retry()
    XCTAssertTrue(fixture.submitted.isEmpty, "B is not sent after C")
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: C", "assistant: Answer C"])
    XCTAssertEqual(app.toast?.text, ChatModel.retryChanged)

    // That old rewind is done with: the next Try again goes back to C, the turn on screen.
    await chat.retry()
    let resent = await eventually { self.fixture.submitted.count == 1 }
    XCTAssertTrue(resent)
    XCTAssertEqual(fixture.submitted.map(\.text), ["C"])
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: C"])
  }

  // MARK: Leaving while the answer is out

  func testReopeningWhileTheAnswerWaitsAndTryingAgainResendsOnce() async throws {
    let (app, old, session) = try await openStored("retry-reopen", seed: [
      ("user", "A"), ("assistant", "Answer A"), ("user", "B"), ("assistant", "Answer B"),
    ])
    app.chatAppeared(old)
    fixture.holdNextMutateAnswer()
    let original = Task { await old.retry() }
    let committed = await eventually { self.fixture.mutateRequests.count == 1 }
    XCTAssertTrue(committed)
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A"], "the rewind landed, its answer is held")

    app.chatDisappeared(old)
    let reopened = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await reopened.open()
    app.chatAppeared(reopened)
    XCTAssertFalse(reopened.isBusy)
    await reopened.retry()
    XCTAssertEqual(fixture.submitted.map(\.text), ["B"], "the reopened copy finished the Try again")

    fixture.release()
    await original.value
    try? await Task.sleep(for: .milliseconds(300))
    let mutations = fixture.mutateRequests
    XCTAssertEqual(Set(mutations.map(\.requestID)).count, 1, "one rewind, sent again")
    XCTAssertEqual(fixture.submitted.map(\.text), ["B"], "the held answer does not send it a second time")
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: B"])
  }

  func testAnAnswerThatComesBackAfterLeavingResendsOnceFromTheCopyOnScreen() async throws {
    let (app, old, session) = try await openStored("retry-reopen-late", seed: [
      ("user", "A"), ("assistant", "Answer A"), ("user", "B"), ("assistant", "Answer B"),
    ])
    app.chatAppeared(old)
    fixture.holdNextMutateAnswer()
    let original = Task { await old.retry() }
    let committed = await eventually { self.fixture.mutateRequests.count == 1 }
    XCTAssertTrue(committed)

    app.chatDisappeared(old)
    let reopened = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await reopened.open()
    app.chatAppeared(reopened)

    fixture.release()
    await original.value
    let resent = await eventually { self.fixture.submitted.count == 1 }
    XCTAssertTrue(resent)
    XCTAssertEqual(fixture.submitted.map(\.text), ["B"])
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: B"])
    XCTAssertEqual(reopened.state.items.filter { $0.kind == .user }.map(\.text), ["A", "B"], "it shows where the person is")
    XCTAssertFalse(reopened.state.items.contains { $0.text == "Answer B" }, "the old answer is gone")

    // Nothing is left to replay: Try again now goes back to B, sent once more.
    fixture.reply(session, "New answer B")
    reopened.handle(GatewayEvent(type: "message.complete", sessionID: reopened.liveID ?? session, payload: ["text": "New answer B"]))
    let settled = await eventually { !reopened.isBusy }
    XCTAssertTrue(settled)
    await reopened.retry()
    let again = await eventually { self.fixture.submitted.count == 2 }
    XCTAssertTrue(again)
    XCTAssertEqual(Set(fixture.mutateRequests.map(\.requestID)).count, 2, "a new rewind, not the old one again")
    XCTAssertEqual(history(session), ["user: A", "assistant: Answer A", "user: B"])
  }

  // MARK: Nothing to try again

  func testWhileAReplyRunsItSaysToWait() async throws {
    let (app, chat, _) = try await openChat("retry-busy", running: true)
    XCTAssertTrue(chat.retryOffers.isEmpty, "no Try again while a reply runs")
    chat.draft = "/retry"
    await chat.send()
    XCTAssertEqual(app.toast?.text, ChatModel.retryBusy, "a toast, not a card inside the running reply")
    XCTAssertTrue(notices(chat).isEmpty)
    XCTAssertTrue(chat.queue.entries.isEmpty, "not queued")
    XCTAssertTrue(fixture.mutateRequests.isEmpty)
  }

  func testNothingToTryAgain() async throws {
    let (_, chat, _) = try await openChat("retry-empty")
    chat.draft = "/retry"
    await chat.send()
    XCTAssertEqual(notices(chat), [ChatModel.retryNothing])
    XCTAssertTrue(fixture.mutateRequests.isEmpty)
  }

  func testAPictureMessageIsNotTriedAgain() async throws {
    let (_, chat, session) = try await openChat("retry-picture", seed: [
      ("user", "@image:/tmp/photo.jpg\n[screenshot]"), ("assistant", "A cat."),
    ])
    chat.draft = "/retry"
    await chat.send()
    XCTAssertEqual(notices(chat), [ChatModel.retryUnsupported])
    XCTAssertTrue(fixture.mutateRequests.isEmpty)
    XCTAssertEqual(history(session).count, 2)
  }
}
