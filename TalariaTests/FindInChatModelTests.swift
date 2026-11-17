import HermesKit
import XCTest

@testable import Talaria

/// Find in chat through the production `ChatFinder`, `ChatModel` and `HermesClient`, against the
/// loopback `GatewayFixture` serving stored messages a page at a time: a long chat opens on its
/// newest page and Find reads the rest. Covers what the offline UI test cannot: pages held for a
/// scroll and then given up on, history replaced under an open search, a failed read retried,
/// and a greeting before the first message.
@MainActor
final class FindInChatModelTests: XCTestCase {
  private var fixture: GatewayFixture!
  private var app: AppModel!
  private var savedAddress = ""

  override func setUp() async throws {
    // Stopping at the first failure unwinds through the async test and hangs it; keep going instead.
    continueAfterFailure = true
    fixture = GatewayFixture()
    try await fixture.start()
    app = AppModel()
    savedAddress = app.preferences.serverAddress
    try await app.connect(to: fixture.address)
    let client = try XCTUnwrap(app.client)
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 10)
  }

  override func tearDown() async throws {
    await app.client?.rpc.stop()
    // `connect` remembers the address; the app's next launch must not look for this fixture.
    app.preferences.serverAddress = savedAddress
    fixture.stop()
  }

  /// A stored chat of `turns` questions and answers; question `needleAt` mentions "needle".
  private func turns(_ count: Int, needleAt: Int? = nil, from first: Int = 1) -> [(role: String, content: JSONValue)] {
    (first..<(first + count)).flatMap { turn -> [(role: String, content: JSONValue)] in
      [("user", .string(turn == needleAt ? "Where did the needle go?" : "Question \(turn)")),
       ("assistant", .string("Answer \(turn)"))]
    }
  }

  /// Opens a stored chat as the app does, on its newest page.
  private func open(_ rows: [(role: String, content: JSONValue)]) async throws -> ChatModel {
    let session = "find-\(UUID().uuidString.prefix(8))"
    fixture.seed(session, rows)
    let chat = ChatModel(app: app, profile: "preview", storedID: session, row: nil, live: nil)
    await chat.open()
    XCTAssertFalse(chat.isLoading)
    XCTAssertTrue(chat.hasOlder, "a long chat opens on its newest page")
    return chat
  }

  private func waitFor(_ timeout: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  private func holdsNeedle(_ chat: ChatModel) -> Bool {
    chat.rows.contains { ChatFind.plainText($0)?.contains("needle") == true }
  }

  /// Settled: nothing read or loading, and a match shown.
  private func settled(_ finder: ChatFinder) -> Bool {
    !finder.isReadingOlder && !finder.isLoadingTarget && finder.current != nil
  }

  func testAnOlderMatchLoadsItsPageAndCounts() async throws {
    let chat = try await open(turns(100, needleAt: 3))
    defer { chat.leave() }
    XCTAssertFalse(holdsNeedle(chat))
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    defer { finder.close() }
    finder.query = "NEEDLE"
    let shown = await waitFor { self.settled(finder) && finder.reveal != nil }
    XCTAssertTrue(shown)
    XCTAssertEqual(finder.status, "1 of 1")
    XCTAssertTrue(holdsNeedle(chat), "the pages down to the match loaded")
  }

  // MARK: Cancelling

  func testDoneDropsAPageHeldUntilScrollingStops() async throws {
    let chat = try await open(turns(100, needleAt: 3))
    defer { chat.leave() }
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    let before = chat.state.items.count
    finder.isScrolling = true
    finder.query = "needle"
    let loading = await waitFor { finder.isLoadingTarget && chat.isLoadingOlder }
    XCTAssertTrue(loading)
    // The page is read; it waits for the scroll to stop.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(chat.state.items.count, before, "no page lands mid-scroll")
    finder.close()
    let stopped = await waitFor { !chat.isLoadingOlder }
    XCTAssertTrue(stopped)
    XCTAssertEqual(chat.state.items.count, before, "Done drops the page it was waiting to land")
    XCTAssertNil(app.toast, "giving up on a page is not a failure")

    // Nothing is left behind to get in the way of the next search.
    let again = ChatFinder(chat: chat) { XCTFail($0) }
    defer { again.close() }
    again.query = "needle"
    let shown = await waitFor { self.settled(again) }
    XCTAssertTrue(shown)
    XCTAssertEqual(again.status, "1 of 1")
    XCTAssertTrue(holdsNeedle(chat))
  }

  func testANewWordDropsAPageHeldForTheOldOne() async throws {
    let chat = try await open(turns(100, needleAt: 3))
    defer { chat.leave() }
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    defer { finder.close() }
    let before = chat.state.items.count
    finder.isScrolling = true
    finder.query = "needle"
    let loading = await waitFor { finder.isLoadingTarget && chat.isLoadingOlder }
    XCTAssertTrue(loading)
    // A word only on the phone: nothing more needs loading.
    finder.query = "answer 100"
    let stopped = await waitFor { !chat.isLoadingOlder }
    XCTAssertTrue(stopped)
    finder.isScrolling = false
    let shown = await waitFor { self.settled(finder) }
    XCTAssertTrue(shown)
    XCTAssertEqual(chat.state.items.count, before, "the old word's page never lands")
    XCTAssertEqual(finder.status, "1 of 1")
    XCTAssertNil(app.toast)
  }

  // MARK: History started over

  func testHistoryReplacedUnderAnOpenSearchIsSearchedAgain() async throws {
    let chat = try await open(turns(200, needleAt: 140))
    defer { chat.leave() }
    let epoch = chat.historyEpoch
    // Scrolled up a page: the match is on the phone.
    await chat.loadOlder()
    XCTAssertTrue(holdsNeedle(chat))
    XCTAssertEqual(chat.historyEpoch, epoch, "a page above extends the history, it does not replace it")
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    defer { finder.close() }
    finder.query = "needle"
    let found = await waitFor { self.settled(finder) }
    XCTAssertTrue(found)
    XCTAssertEqual(finder.status, "1 of 1")

    // Away for a while: another device adds more than a page, so the reattach starts over on the
    // newest page and the match is only on the Mac again.
    let reads = fixture.historyReadCount
    let session = chat.storedID
    for turn in 201...250 { fixture.sendFromAnotherDevice(session, "Question \(turn)", reply: "Answer \(turn)") }
    await chat.connectionReady()
    XCTAssertFalse(holdsNeedle(chat))
    XCTAssertNotEqual(chat.historyEpoch, epoch)
    let again = await waitFor { !finder.isReadingOlder && finder.hits.count == 1 }
    XCTAssertTrue(again, "the stored message is found again without typing")
    XCTAssertGreaterThan(fixture.historyReadCount, reads + 1, "the rest of the chat was read again")
    XCTAssertEqual(finder.status, "1 of 1", "the match shown keeps its place in the count")
    finder.query = "needle "
    let typed = await waitFor { !finder.isReadingOlder && finder.hits.count == 1 }
    XCTAssertTrue(typed)
  }

  func testAReadForAReplacedHistoryIsDropped() async throws {
    let chat = try await open(turns(200, needleAt: 140))
    defer { chat.leave() }
    await chat.loadOlder()
    XCTAssertTrue(holdsNeedle(chat))
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    defer { finder.close() }
    // The search's read is slow; the history is started over while it is under way.
    fixture.delayHistory(0.6)
    finder.query = "needle"
    let reading = await waitFor { finder.isReadingOlder }
    XCTAssertTrue(reading)
    for turn in 201...250 { fixture.sendFromAnotherDevice(chat.storedID, "Question \(turn)", reply: "Answer \(turn)") }
    await chat.connectionReady()
    XCTAssertFalse(holdsNeedle(chat))
    let done = await waitFor(10) { !finder.isReadingOlder && finder.hits.count == 1 }
    XCTAssertTrue(done, "counted once, from a read of the history now held")
    fixture.delayHistory(0)
  }

  // MARK: A failed read

  func testAFailedReadSaysSoAndCanBeTriedAgain() async throws {
    let chat = try await open(turns(100, needleAt: 3))
    defer { chat.leave() }
    var reports: [String] = []
    let finder = ChatFinder(chat: chat) { reports.append($0) }
    defer { finder.close() }
    fixture.failHistory(true)
    finder.query = "needle"
    let failed = await waitFor { !finder.isReadingOlder && finder.olderUnread }
    XCTAssertTrue(failed)
    XCTAssertEqual(reports.count, 1)
    XCTAssertEqual(finder.status, "Older not searched", "not \"No matches\": the older messages were never read")
    XCTAssertTrue(finder.canRetry)

    // Back again: the retry reads the rest of the chat.
    fixture.failHistory(false)
    let reads = fixture.historyReadCount
    finder.retryOlder()
    let shown = await waitFor { self.settled(finder) }
    XCTAssertTrue(shown)
    XCTAssertGreaterThan(fixture.historyReadCount, reads)
    XCTAssertFalse(finder.olderUnread)
    XCTAssertEqual(finder.status, "1 of 1")
  }

  func testANewWordAfterAFailedReadReadsAgain() async throws {
    let chat = try await open(turns(100, needleAt: 3))
    defer { chat.leave() }
    let finder = ChatFinder(chat: chat) { _ in }
    defer { finder.close() }
    fixture.failHistory(true)
    finder.query = "needle"
    let failed = await waitFor { !finder.isReadingOlder && finder.olderUnread }
    XCTAssertTrue(failed)
    let reads = fixture.historyReadCount
    fixture.failHistory(false)
    finder.query = "needle go"
    let shown = await waitFor { self.settled(finder) }
    XCTAssertTrue(shown)
    XCTAssertGreaterThan(fixture.historyReadCount, reads, "the next word reads the older messages again")
    XCTAssertEqual(finder.status, "1 of 1")
  }

  // MARK: Before the first message

  func testAGreetingKeepsItsPlaceInTheCountOnceLoaded() async throws {
    let chat = try await open([("assistant", .string("Hello, the needle is safe."))] + turns(100, needleAt: 100))
    defer { chat.leave() }
    let finder = ChatFinder(chat: chat) { XCTFail($0) }
    defer { finder.close() }
    finder.query = "needle"
    let first = await waitFor { self.settled(finder) }
    XCTAssertTrue(first)
    XCTAssertEqual(finder.status, "1 of 2")
    finder.older()
    let loaded = await waitFor(10) { !finder.isLoadingTarget && !chat.hasOlder && finder.status == "2 of 2" }
    XCTAssertTrue(loaded, "status \(finder.status)")
    XCTAssertTrue(chat.rows.contains { $0.id == finder.reveal?.row }, "the step landed on the greeting's row")
    XCTAssertTrue(finder.canGoNewer)
    XCTAssertFalse(finder.canGoOlder)
    finder.newer()
    XCTAssertEqual(finder.status, "1 of 2")
  }
}
