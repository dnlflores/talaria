import Foundation
import MarkdownBlocks

/// Find in a chat: the messages a word appears in, read as they show on screen.
///
/// Only what the person reads as the conversation is searched: their messages, the bot's
/// answers and its progress notes. Tool calls and their output, thinking, edits and notices are
/// not. Matching ignores case, accents and width, and runs on the plain text of a message, so
/// Markdown markers (`**`, `#`, backticks, link targets) never match and never split a word.
///
/// A chat holds only its newest pages, so Find searches two lists: the rows on the phone, and the
/// older rows read from the Mac for the search alone. A match in the older list is found again
/// once its page is loaded by its `Place`: the turn it is in (the stored row id of the person's
/// message that starts it) and its position among the turn's searchable rows. Pages always start
/// at a turn, so a turn reads the same in either list.
public enum ChatFind {
  /// Where a searchable row sits, the same in any copy of the transcript that holds its turn.
  public struct Place: Hashable, Sendable {
    /// Stored row id of the message from the person that starts the turn. Nil before the first
    /// one, or when that message was sent from here and the Mac's copy has not named it yet.
    public var turn: Int?
    /// Position among the turn's searchable rows; the person's message is 0.
    public var ordinal: Int
    /// Before the chat's first message from the person (a greeting), in a copy that holds the
    /// chat's start. Such rows are the same in every copy that holds it, by `ordinal`.
    public var opensChat: Bool

    public init(turn: Int?, ordinal: Int, opensChat: Bool = false) {
      self.turn = turn
      self.ordinal = ordinal
      self.opensChat = opensChat
    }
  }

  /// One searchable row: its id in the list it came from, where it is, and its folded text.
  public struct Entry: Equatable, Sendable {
    public var row: UUID
    public var place: Place
    public var text: String
  }

  /// One message the word appears in.
  public struct Hit: Equatable, Sendable {
    /// The row's id in the list it was found in. Rows read again get new ids.
    public var row: UUID
    public var place: Place

    public init(row: UUID, place: Place) {
      self.row = row
      self.place = place
    }

    /// The same message, found in this list or another copy of it. Rows of a turn the Mac has not
    /// named yet only match themselves: two of those can share a place.
    public func isSame(as other: Hit) -> Bool {
      if let turn = place.turn, other.place.turn == turn { return place.ordinal == other.place.ordinal }
      if place.opensChat, other.place.opensChat { return place.ordinal == other.place.ordinal }
      return row == other.row
    }
  }

  // MARK: Text

  /// Case, accent and width folded, every run of white space one space.
  public static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
  }

  /// A row's text as it reads on screen, or nil for rows Find leaves out.
  public static func plainText(_ row: TranscriptRow) -> String? {
    switch row {
    case .user(let item):
      // Shown as typed, without Markdown.
      return item.text
    case .answer(let item), .commentary(let item):
      return plainText(markdown: item.isStreaming ? item.text : FileExtraction.hidingMediaLines(item.text))
    case .work, .question, .edit, .system, .side, .files:
      return nil
    }
  }

  /// Markdown as the transcript renders it, without its markers: one line per block, inline
  /// emphasis, code spans and links reduced to their words, code blocks as written.
  public static func plainText(markdown: String) -> String {
    MarkdownParser.parse(markdown).map(plainText(block:)).joined(separator: "\n")
  }

  private static func plainText(block: MarkdownBlock) -> String {
    switch block {
    case .paragraph(let source), .heading(_, let source):
      return inline(source)
    case .code(_, let text):
      return text
    case .list(_, _, let items):
      return items.map { $0.blocks.map(plainText(block:)).joined(separator: "\n") }.joined(separator: "\n")
    case .quote(let blocks):
      return blocks.map(plainText(block:)).joined(separator: "\n")
    case .table(let header, let rows):
      return ([header] + rows).map { $0.map(inline).joined(separator: " ") }.joined(separator: "\n")
    case .rule:
      return ""
    }
  }

  private static func inline(_ source: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: source, options: options) else { return source }
    return String(parsed.characters)
  }

  // MARK: Searching

  /// The searchable rows of a transcript, oldest first, each with its place. `holdsStart`: the
  /// rows begin where the chat does, so any before the first message from the person open it.
  public static func entries(_ rows: [TranscriptRow], holdsStart: Bool = true) -> [Entry] {
    var index = Index()
    return index.entries(rows, holdsStart: holdsStart)
  }

  /// The messages `query` appears in, newest first. An empty query finds nothing.
  public static func hits(in entries: [Entry], query: String) -> [Hit] {
    let needle = fold(query)
    guard !needle.isEmpty else { return [] }
    return entries.reversed().filter { $0.text.contains(needle) }.map { Hit(row: $0.row, place: $0.place) }
  }

  public static func hits(in rows: [TranscriptRow], query: String) -> [Hit] {
    hits(in: entries(rows), query: query)
  }

  /// Entries for a transcript that changes while Find is open (a reply streaming in), keeping
  /// each row's folded text until the row's words change.
  public struct Index: Sendable {
    private var folded: [UUID: (source: String, text: String)] = [:]

    public init() {}

    public mutating func entries(_ rows: [TranscriptRow], holdsStart: Bool = true) -> [Entry] {
      var entries: [Entry] = []
      var seen = Set<UUID>()
      var turn: Int?
      var ordinal = 0
      var opensChat = holdsStart
      for row in rows {
        guard let source = ChatFind.source(row) else { continue }
        if case .user(let item) = row {
          turn = item.rowID
          ordinal = 0
          opensChat = false
        } else {
          ordinal += 1
        }
        let text: String
        if let held = folded[row.id], held.source == source {
          text = held.text
        } else {
          text = row.plainFolded
          folded[row.id] = (source, text)
        }
        seen.insert(row.id)
        entries.append(Entry(row: row.id, place: Place(turn: turn, ordinal: ordinal, opensChat: opensChat), text: text))
      }
      if folded.count > seen.count { folded = folded.filter { seen.contains($0.key) } }
      return entries
    }
  }

  /// What a row's searchable text is made from, to tell when it changed; nil for rows left out.
  static func source(_ row: TranscriptRow) -> String? {
    switch row {
    case .user(let item), .answer(let item), .commentary(let item):
      return item.isStreaming ? "s" + item.text : "f" + item.text
    case .work, .question, .edit, .system, .side, .files:
      return nil
    }
  }
}

extension TranscriptRow {
  fileprivate var plainFolded: String { ChatFind.fold(ChatFind.plainText(self) ?? "") }
}
