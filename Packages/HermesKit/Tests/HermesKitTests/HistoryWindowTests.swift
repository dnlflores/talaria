import Foundation
import Testing

@testable import HermesKit

/// A conversation's stored rows as `GET /api/sessions/{id}/messages?order=latest` pages them.
private final class FakeStore: @unchecked Sendable {
  var rows: [JSONValue] = []
  var reads: [(offset: Int, limit: Int)] = []
  private var nextID = 1
  private var call = 0

  /// One turn: the user's words, `steps` assistant rows each calling `parallel` tools with their
  /// results, then the answer.
  func turn(_ words: String, steps: Int, parallel: Int = 1) {
    add(["role": "user", "content": .string(words)])
    for step in 0..<steps {
      let ids = (0..<parallel).map { _ -> String in
        call += 1
        return "call-\(call)"
      }
      add([
        "role": "assistant", "content": .string(step == 0 ? "Looking into \(words)." : ""),
        "tool_calls": .array(ids.map { ["id": .string($0), "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]] }),
      ])
      for id in ids { add(["role": "tool", "tool_call_id": .string(id), "content": .string("output of \(id)")]) }
    }
    add(["role": "assistant", "content": .string("Answer to \(words).")])
  }

  private func add(_ row: [String: JSONValue]) {
    var row = row
    row["id"] = .number(Double(nextID))
    row["timestamp"] = .number(Double(1_000 + nextID))
    nextID += 1
    rows.append(.object(row))
  }

  func page(offset: Int, limit: Int) -> [JSONValue] {
    reads.append((offset, limit))
    let newestFirst = Array(rows.reversed())
    guard offset < newestFirst.count else { return [] }
    return Array(newestFirst[offset..<min(offset + limit, newestFirst.count)].reversed())
  }
}

private func ids(_ rows: [JSONValue]) -> [Int] { rows.compactMap { $0["id"].int } }

@Suite struct HistoryWindowTests {
  @Test func readsNewestFirstThenOlderWithoutGapsOrRepeats() async throws {
    let store = FakeStore()
    for index in 0..<12 { store.turn("question \(index)", steps: 3 + index % 4, parallel: 1 + index % 3) }
    var window = HistoryWindow()
    var held = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 20, nextLimit: 30, fetch: { store.page(offset: $0, limit: $1) },
      until: { TranscriptItem.items(fromStoredRows: $0).contains { $0.kind == .user } })
    #expect(window.hasOlder)
    #expect(TranscriptItem.items(fromStoredRows: held).first?.kind != nil)
    while window.hasOlder {
      let older = try await HistoryWindow.readOlder(
        into: &window, firstLimit: 30, nextLimit: 30, fetch: { store.page(offset: $0, limit: $1) },
        until: { !TranscriptItem.items(fromStoredRows: $0).isEmpty })
      held = older + held
    }
    #expect(ids(held) == ids(store.rows))
    // Read page by page, the transcript is the same as read whole: no call lost its result.
    #expect(TranscriptItem.items(fromStoredRows: held).map(\.signature) == TranscriptItem.items(fromStoredRows: store.rows).map(\.signature))
    #expect(TranscriptItem.items(fromStoredRows: held).allSatisfy { $0.tool?.isDone != false })
  }

  /// A page that starts with results leaves them for the next page, which holds their call.
  @Test func resultsWaitForTheirCall() {
    let store = FakeStore()
    store.turn("one", steps: 1, parallel: 4)
    store.turn("two", steps: 1)
    // Newest 6 rows: three results of "one", its answer, then "two"'s user... reversed order check.
    var window = HistoryWindow()
    let page = store.page(offset: 0, limit: 7)
    let rows = window.take(page: page, limit: 7) ?? []
    #expect(rows.first?["role"].string != "tool")
    #expect(window.covered == 7 - (page.count - rows.count))
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.allSatisfy { $0.tool?.isDone != false })
  }

  @Test func aPageOfOnlyResultsAsksForMore() async throws {
    let store = FakeStore()
    store.turn("wide", steps: 1, parallel: 12)
    store.turn("after", steps: 0)
    var window = HistoryWindow()
    // The newest 3 rows are "after" and the wide turn's answer; the next 12 are all results of one call row.
    _ = window.take(page: store.page(offset: 0, limit: 3), limit: 3)
    let onlyResults = window.take(page: store.page(offset: window.covered, limit: 10), limit: 10)
    #expect(onlyResults == nil)
    let older = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 10, nextLimit: 10, fetch: { store.page(offset: $0, limit: $1) }, until: { !$0.isEmpty })
    #expect(older.first?["role"].string == "assistant" || older.first?["role"].string == "user")
    #expect(TranscriptItem.items(fromStoredRows: older).filter { $0.kind == .tool }.allSatisfy { $0.tool?.isDone == true })
  }

  /// Rows written after the first read move every offset back; the older pages still meet the
  /// held rows exactly, and the new rows are counted when the newest page is folded in.
  @Test func rowsWrittenMeanwhileNeitherRepeatNorSkip() async throws {
    let store = FakeStore()
    for index in 0..<8 { store.turn("q\(index)", steps: 2) }
    var window = HistoryWindow()
    let newest = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 15, nextLimit: 15, fetch: { store.page(offset: $0, limit: $1) }, until: { _ in true })
    let before = store.rows.count
    store.turn("new while open", steps: 3)
    let added = store.rows.count - before
    let older = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 15, nextLimit: 15, fetch: { store.page(offset: $0, limit: $1) }, until: { _ in true })
    #expect(Set(ids(older)).isDisjoint(with: ids(newest)))
    #expect(ids(older + newest) == Array(ids(store.rows).prefix(before).suffix(older.count + newest.count)))
    // Folding in the newest page takes in the new rows.
    let tail = store.page(offset: 0, limit: 15)
    #expect(window.overlaps(newest: tail))
    window.absorb(newest: tail)
    // The next older page starts right above the oldest row held.
    let oldestHeld = try #require(store.rows.firstIndex { $0["id"].int == ids(older).first })
    #expect(window.covered == store.rows.count - oldestHeld)
    var all = older + newest + Array(store.rows.suffix(added))
    while window.hasOlder {
      all = try await HistoryWindow.readOlder(
        into: &window, firstLimit: 15, nextLimit: 15, fetch: { store.page(offset: $0, limit: $1) }, until: { _ in true }) + all
    }
    #expect(ids(all) == ids(store.rows))
  }

  /// Read in whole turns, every page starts with what was said to the agent, and the rows of a
  /// turn cut by the page come with the next one.
  @Test func wholeTurnsStartWithTheUser() async throws {
    let store = FakeStore()
    for index in 0..<10 { store.turn("question \(index)", steps: 4 + index % 3, parallel: 1 + index % 2) }
    var window = HistoryWindow()
    var held: [JSONValue] = []
    var pages = 0
    repeat {
      let older = try await HistoryWindow.readOlder(
        into: &window, firstLimit: 17, nextLimit: 17, wholeTurns: true, fetch: { store.page(offset: $0, limit: $1) },
        until: { $0.contains(where: HistoryWindow.startsTurn) })
      #expect(older.first?["role"].string == "user")
      held = older + held
      pages += 1
    } while window.hasOlder && pages < 50
    #expect(!window.hasOlder)
    #expect(ids(held) == ids(store.rows))
  }

  /// A notice Hermes wrote as a user row shows inside the turn before it, so a page does not
  /// start there.
  @Test func noticesDoNotStartATurn() {
    let notice: JSONValue = ["id": 1, "role": "user", "display_kind": "process_complete", "content": "[IMPORTANT: Background process done.]"]
    let system: JSONValue = ["id": 2, "role": "user", "content": "[System: the model was switched]"]
    let said: JSONValue = ["id": 3, "role": "user", "content": "go on"]
    #expect(!HistoryWindow.startsTurn(notice))
    #expect(!HistoryWindow.startsTurn(system))
    #expect(HistoryWindow.startsTurn(said))
  }

  /// A turn longer than a page is read on until it starts.
  @Test func aLongTurnIsReadToItsStart() async throws {
    let store = FakeStore()
    for index in 0..<30 { store.turn("earlier \(index)", steps: 2) }
    store.turn("long one", steps: 30, parallel: 2)
    var window = HistoryWindow()
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 20, nextLimit: 20, wholeTurns: true, fetch: { store.page(offset: $0, limit: $1) },
      until: { $0.contains(where: HistoryWindow.startsTurn) })
    #expect(rows.first.map(HistoryWindow.startsTurn) == true)
    #expect(rows.contains { $0["content"].string == "long one" })
    #expect(window.hasOlder)
    var all = rows
    while window.hasOlder {
      all = try await HistoryWindow.readOlder(
        into: &window, firstLimit: 20, nextLimit: 20, wholeTurns: true, fetch: { store.page(offset: $0, limit: $1) },
        until: { $0.contains(where: HistoryWindow.startsTurn) }) + all
    }
    #expect(ids(all) == ids(store.rows))
  }

  @Test func aShortChatIsReadWhole() async throws {
    let store = FakeStore()
    store.turn("hi", steps: 1)
    var window = HistoryWindow()
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: 60, nextLimit: 100, fetch: { store.page(offset: $0, limit: $1) }, until: { _ in false })
    #expect(ids(rows) == ids(store.rows))
    #expect(!window.hasOlder)
    #expect(store.reads.count == 1)
  }

  @Test func aNewestPageFromAfterAGapDoesNotOverlap() {
    let store = FakeStore()
    store.turn("old", steps: 1)
    var window = HistoryWindow()
    _ = window.take(page: store.page(offset: 0, limit: 10), limit: 10)
    for index in 0..<10 { store.turn("later \(index)", steps: 2) }
    #expect(!window.overlaps(newest: store.page(offset: 0, limit: 10)))
  }
}

@Suite struct ReconcileTailTests {
  private func items(_ texts: [String]) -> [TranscriptItem] {
    texts.map { text in
      text.hasPrefix("u:") ? TranscriptItem.user(String(text.dropFirst(2)), timestamp: 1) : TranscriptItem(kind: .assistant, text: text, timestamp: 1)
    }
  }

  @Test func alignment() {
    // The page starts inside what is held.
    #expect(ChatState.alignment(held: ["a", "b", "c"], page: ["b", "c", "d"]) == 2)
    // The page reaches back past everything held.
    #expect(ChatState.alignment(held: ["b", "c"], page: ["a", "b", "c", "d"]) == 3)
    // Nothing new.
    #expect(ChatState.alignment(held: ["a", "b", "c"], page: ["b", "c"]) == 2)
    // Does not line up.
    #expect(ChatState.alignment(held: ["a", "b", "c"], page: ["x", "y"]) == nil)
    #expect(ChatState.alignment(held: [], page: ["x"]) == 0)
  }

  @Test func newRowsGoOnTheEndAndHeldItemsKeepTheirIdentity() {
    var state = ChatState()
    state.items = items(["u:older", "older answer", "u:recent", "recent answer"])
    let ids = state.items.map(\.id)
    let folded = state.reconcileTail(fresh: items(["u:recent", "recent answer", "u:new", "new answer"]), inflight: .null, now: 10)
    #expect(folded)
    #expect(state.items.map(\.text) == ["older", "older answer", "recent", "recent answer", "new", "new answer"])
    #expect(Array(state.items.map(\.id).prefix(4)) == ids)
  }

  @Test func aPageThatDoesNotLineUpTouchesNothing() {
    var state = ChatState()
    state.items = items(["u:a", "answer a"])
    let before = state
    let folded = state.reconcileTail(fresh: items(["u:z", "answer z"]), inflight: .null, now: 10)
    #expect(!folded)
    #expect(state == before)
  }

  @Test func aMessageTypedHereLandsOnce() {
    var state = ChatState()
    state.items = items(["u:a", "answer a"])
    var pending = TranscriptItem.user("b", timestamp: 5)
    pending.isPending = true
    state.items.append(pending)
    let folded = state.reconcileTail(fresh: items(["u:a", "answer a", "u:b", "answer b"]), inflight: .null, now: 10)
    #expect(folded)
    #expect(state.items.filter { $0.kind == .user && $0.text == "b" }.count == 1)
    #expect(state.items.last?.text == "answer b")
  }

  @Test func replaceKeepsWhatIsStillUnsent() {
    var state = ChatState()
    state.items = items(["u:a", "answer a"])
    var pending = TranscriptItem.user("unsent", timestamp: 5)
    pending.isPending = true
    state.items.append(pending)
    state.replace(with: items(["u:z", "answer z"]), inflight: .null, now: 10)
    #expect(state.items.map(\.text) == ["z", "answer z", "unsent"])
  }
}

@Suite struct StoredRowDisplayTests {
  @Test func noticesHermesWroteAreSystemLines() {
    let rows: [JSONValue] = [
      ["id": 1, "role": "user", "content": "Do the thing"],
      ["id": 2, "role": "user", "display_kind": "process_complete", "content": "[IMPORTANT: Background process proc_1 exited (exit code 0)."],
      ["id": 3, "role": "user", "content": "[System: the model was switched]"],
      ["id": 4, "role": "user", "content": "[System note: Your previous turn was interrupted mid-run. Continue.]"],
      ["id": 5, "role": "user", "display_kind": "hidden", "content": "scaffolding"],
      ["id": 6, "role": "user", "display_kind": "steer", "content": "[OUT-OF-BAND USER MESSAGE]\nwrapped", "display_content": "also check the logs"],
    ]
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.map(\.kind) == [.user, .system, .system, .user])
    #expect(items.last?.text == "also check the logs")
  }

  @Test func aSkillTurnShowsAsItsInvocation() {
    let stored = """
      [IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions. \
      The full skill content is loaded below.]

      # Work skill body that is very long

      The user has provided the following instruction alongside the skill invocation: fix   the leak

      [Runtime note: something]
      """
    #expect(SkillInvocation.text(stored) == "/work fix the leak")
    #expect(SkillInvocation.text("plain words") == nil)
    let items = TranscriptItem.items(fromStoredRows: [["id": 1, "role": "user", "content": .string(stored)]])
    #expect(items.first?.text == "/work fix the leak")
  }

  @Test func thinkingWithoutWordsAndHiddenWordsWithCalls() {
    let rows: [JSONValue] = [
      ["id": 1, "role": "user", "content": "go"],
      [
        "id": 2, "role": "assistant", "content": "", "reasoning": "planning",
        "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{}"]]],
      ],
      ["id": 3, "role": "tool", "tool_call_id": "c1", "content": "ok"],
      [
        "id": 4, "role": "assistant", "display_kind": "hidden", "content": "model-only words",
        "tool_calls": [["id": "c2", "function": ["name": "read_file", "arguments": "{}"]]],
      ],
      ["id": 5, "role": "tool", "tool_call_id": "c2", "content": "ok"],
    ]
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.map(\.kind) == [.user, .assistant, .tool, .tool])
    #expect(items[1].reasoning == "planning")
    #expect(!items.contains { $0.text == "model-only words" })
  }
}
