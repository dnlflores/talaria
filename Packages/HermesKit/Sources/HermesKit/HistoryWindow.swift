import Foundation

/// The part of a conversation's stored history the app holds, and where the next older page starts.
///
/// Long conversations hold hundreds of rows, most of them tool calls and their output, so a chat
/// opens on its newest page and reads older pages as the transcript is scrolled up. Pages come
/// from `GET /api/sessions/{id}/messages?order=latest`: offsets count back from the newest row
/// and each page is returned oldest first, as the desktop app reads them.
///
/// Two things move under a reader:
/// - Rows written after a page was read shift every offset, so the next older page can repeat
///   rows already held. Those are recognised by their row id and dropped, and the offset still
///   advances by the whole page, which puts it right again.
/// - A page can begin with tool results whose call sits in the row before it. Those rows wait for
///   the next page, so every page starts where a turn or a step starts and a call is never shown
///   as running for want of its result.
///
/// Read with `wholeTurns`, a page that reaches a turn's start gives the rows before it back for the
/// next page: a turn is then not shown in part, so nothing in it (its steps, the files it made)
/// changes when the rest of it arrives. `until` decides how far to read for one.
public struct HistoryWindow: Sendable, Equatable {
  /// Rows counted back from the newest that this window covers: where the next older page starts.
  public private(set) var covered = 0
  /// The oldest row has been read; there is nothing older.
  public private(set) var reachedStart = false
  /// Ids of the stored rows read so far.
  private var loaded: Set<String> = []

  public init() {}

  /// A conversation held in full (a new chat, or a copy that came with its whole history).
  public static var complete: HistoryWindow {
    var window = HistoryWindow()
    window.reachedStart = true
    return window
  }

  public var hasOlder: Bool { !reachedStart }

  /// The rows of a page, read at offset `covered` with `limit`, that this window does not hold
  /// yet, oldest first. `nil` when the page held nothing but results of calls made in older rows:
  /// read it again with a larger limit.
  public mutating func take(page: [JSONValue], limit: Int) -> [JSONValue]? {
    let full = page.count >= limit
    var rows = page.filter { !loaded.contains(Self.id($0)) }
    var deferred = 0
    if full {
      let lead = rows.prefix { $0["role"].string == "tool" }.count
      if lead > 0, lead == rows.count { return nil }
      rows.removeFirst(lead)
      deferred = lead
    }
    covered += page.count - deferred
    if !full { reachedStart = true }
    remember(rows)
    return rows
  }

  /// Whether the newest page (read at offset 0) reaches back to rows this window holds. When it
  /// does not, more happened since than one page shows, and the window starts over from that page.
  public func overlaps(newest page: [JSONValue]) -> Bool {
    page.contains { loaded.contains(Self.id($0)) }
  }

  /// Takes in the rows of the newest page written after the newest row this window holds. Call
  /// it once those rows are on screen.
  ///
  /// The rows held run unbroken from the oldest read to the newest, so they are exactly what lies
  /// between the next older page and the newest row: their count is where that page starts. (A
  /// page read meanwhile may have counted the new rows already, from the rows it repeated.)
  public mutating func absorb(newest page: [JSONValue]) {
    guard let lastHeld = page.lastIndex(where: { loaded.contains(Self.id($0)) }) else { return }
    remember(page[(lastHeld + 1)...])
    covered = loaded.count
  }

  /// Starts a window over a conversation held in full whose rows had no ids (a copy that came
  /// with its whole history): the newest page names the rows from here on.
  public mutating func identify(newest page: [JSONValue]) {
    guard reachedStart, loaded.isEmpty else { return }
    remember(page)
  }

  /// A page with its leading tool results left out when older rows may hold their calls: the
  /// shape `TranscriptItem.items(fromStoredRows:)` needs.
  public static func startingCleanly(_ page: [JSONValue], limit: Int) -> [JSONValue] {
    guard page.count >= limit else { return page }
    let lead = page.prefix { $0["role"].string == "tool" }.count
    return lead == page.count ? page : Array(page.dropFirst(lead))
  }

  /// Hands back the oldest rows read, for the next older page to read again.
  mutating func giveBack<Rows: Collection>(_ rows: Rows) where Rows.Element == JSONValue {
    guard !rows.isEmpty else { return }
    for row in rows { loaded.remove(Self.id(row)) }
    covered -= rows.count
    reachedStart = false
  }

  /// A stored row that starts a turn as the transcript shows it: a message from the person.
  /// (Notices Hermes writes as user rows, like a background process finishing, sit inside the
  /// turn before them on screen.)
  public static func startsTurn(_ row: JSONValue) -> Bool {
    row["role"].string == "user" && TranscriptItem.items(fromStoredRows: [row]).contains { $0.kind == .user }
  }

  private mutating func remember<Rows: Sequence>(_ rows: Rows) where Rows.Element == JSONValue {
    for row in rows {
      let id = Self.id(row)
      if !id.isEmpty { loaded.insert(id) }
    }
  }

  static func id(_ row: JSONValue) -> String { row["id"].scalarText ?? "" }
}

extension HistoryWindow {
  /// Reads older pages into `window` until `done` holds for what was read or the start is
  /// reached. Returns the rows read, oldest first, ready to go above what is held.
  ///
  /// - Parameters:
  ///   - firstLimit: rows asked for in the first read.
  ///   - nextLimit: rows asked for in each read after it.
  ///   - wholeTurns: give back the rows before the oldest turn start read.
  ///   - fetch: reads `limit` rows at `offset` (`order=latest`), oldest first.
  public static func readOlder(
    into window: inout HistoryWindow, firstLimit: Int, nextLimit: Int, wholeTurns: Bool = false,
    isolation: isolated (any Actor)? = #isolation,
    fetch: (_ offset: Int, _ limit: Int) async throws -> [JSONValue],
    until done: ([JSONValue]) -> Bool
  ) async throws -> [JSONValue] {
    var rows: [JSONValue] = []
    var limit = firstLimit
    var reads = 0
    while !window.reachedStart {
      reads += 1
      // A runaway (pages of nothing but results, or a store that keeps shifting) stops here.
      if reads > 200 { break }
      let page = try await fetch(window.covered, limit)
      guard let chunk = window.take(page: page, limit: limit) else {
        limit *= 2
        continue
      }
      rows = chunk + rows
      if done(rows) { break }
      // Reading on through one long turn: fewer, larger reads.
      limit = reads == 1 ? nextLimit : min(limit * 2, nextLimit * 8)
    }
    // Rows before the first turn at the very start of the conversation have nothing older to wait for.
    if wholeTurns, !window.reachedStart, let start = rows.firstIndex(where: startsTurn), start > 0 {
      window.giveBack(rows[..<start])
      rows.removeFirst(start)
    }
    return rows
  }
}
