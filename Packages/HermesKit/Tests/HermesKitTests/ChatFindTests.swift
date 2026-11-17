import Foundation
import Testing

@testable import HermesKit

/// Find in a chat: which rows count, how words are folded and stripped of Markdown, the order
/// matches come in, and finding an older match again once its page is loaded.
struct ChatFindTests {
  private func rows(_ json: String) throws -> [TranscriptRow] {
    let stored = try JSONValue.parse(json).array ?? []
    return TranscriptLayout.rows(for: TranscriptItem.items(fromStoredRows: stored), isStreaming: false)
  }

  private func texts(_ hits: [ChatFind.Hit], in rows: [TranscriptRow]) -> [String] {
    hits.compactMap { hit in rows.first { $0.id == hit.row }.flatMap(ChatFind.plainText) }
  }

  // MARK: Which rows count

  @Test func searchesMessagesAnswersAndProgressNotesOnly() throws {
    let transcript = try rows("""
      [
        {"id": 1, "role": "user", "content": "Where is the walrus config?"},
        {"id": 2, "role": "assistant", "content": "Looking for the walrus file first.",
         "reasoning": "The walrus is probably in config.",
         "tool_calls": [{"id": "c1", "function": {"name": "search_files", "arguments": "{\\"pattern\\": \\"walrus\\"}"}}]},
        {"id": 3, "role": "tool", "tool_call_id": "c1", "content": "walrus.yaml"},
        {"id": 4, "role": "assistant", "content": "",
         "tool_calls": [{"id": "c2", "function": {"name": "patch", "arguments": "{\\"path\\": \\"walrus.yaml\\"}"}}]},
        {"id": 5, "role": "tool", "tool_call_id": "c2", "content": "{\\"success\\": true}",
         "display_metadata": {"inline_diff": "a/walrus.yaml -> b/walrus.yaml\\n+walrus: true"}},
        {"id": 6, "role": "assistant", "content": "The walrus config is in walrus.yaml."}
      ]
      """)
    let hits = ChatFind.hits(in: transcript, query: "walrus")
    #expect(texts(hits, in: transcript) == [
      "The walrus config is in walrus.yaml.",
      "Looking for the walrus file first.",
      "Where is the walrus config?",
    ])
    // Thinking, the search call and its output, and the edit are all left out.
    #expect(ChatFind.entries(transcript).count == 3)
  }

  @Test func leavesOutNoticesSideCardsAndQuestions() {
    var notice = TranscriptItem(kind: .system, text: "walrus notice")
    notice.isLocal = true
    let side = TranscriptItem(kind: .side, text: "walrus side")
    let transcript: [TranscriptRow] = [.system(notice), .side(side), .question(TranscriptItem(kind: .tool, text: "walrus?"))]
    #expect(ChatFind.hits(in: transcript, query: "walrus").isEmpty)
  }

  // MARK: Folding and Markdown

  @Test func ignoresCaseAccentsAndWidth() throws {
    let transcript = try rows("""
      [
        {"id": 1, "role": "user", "content": "Ship the ZÉPHYR build"},
        {"id": 2, "role": "assistant", "content": "Zéphyr is out. ｚｅｐｈｙｒ too."}
      ]
      """)
    #expect(ChatFind.hits(in: transcript, query: "zephyr").count == 2)
    #expect(ChatFind.hits(in: transcript, query: "Zéphyr").count == 2)
    #expect(ChatFind.hits(in: transcript, query: "  ZEPHYR ").count == 2)
  }

  @Test func matchesThePlainTextOfMarkdown() throws {
    let transcript = try rows("""
      [
        {"id": 1, "role": "user", "content": "Summarize it"},
        {"id": 2, "role": "assistant", "content": "# Release\\n\\nThe **new** `build` ships [today](https://example.com/notes).\\n\\n- one *item*\\n- two\\n\\n```swift\\nlet value = 1\\n```"}
      ]
      """)
    #expect(ChatFind.hits(in: transcript, query: "the new build ships today").count == 1)
    #expect(ChatFind.hits(in: transcript, query: "release").count == 1)
    #expect(ChatFind.hits(in: transcript, query: "one item").count == 1)
    #expect(ChatFind.hits(in: transcript, query: "let value = 1").count == 1)
    // Markers and link targets are not part of what reads on screen.
    #expect(ChatFind.hits(in: transcript, query: "**").isEmpty)
    #expect(ChatFind.hits(in: transcript, query: "#").isEmpty)
    #expect(ChatFind.hits(in: transcript, query: "`").isEmpty)
    #expect(ChatFind.hits(in: transcript, query: "example.com").isEmpty)
    #expect(ChatFind.plainText(markdown: "A **bold** and _soft_ ~~old~~ word") == "A bold and soft old word")
  }

  @Test func userMessagesAreSearchedAsTyped() throws {
    // The person's bubble shows their words as typed, Markdown characters included.
    let transcript = try rows(#"[{"id": 1, "role": "user", "content": "Use **stars** here"}]"#)
    #expect(ChatFind.hits(in: transcript, query: "**stars**").count == 1)
  }

  @Test func wordsAcrossALineBreakStillMatch() throws {
    let transcript = try rows(#"[{"id": 1, "role": "user", "content": "first\n  second"}]"#)
    #expect(ChatFind.hits(in: transcript, query: "first second").count == 1)
  }

  @Test func emptyQueryFindsNothing() throws {
    let transcript = try rows(#"[{"id": 1, "role": "user", "content": "anything"}]"#)
    #expect(ChatFind.hits(in: transcript, query: "").isEmpty)
    #expect(ChatFind.hits(in: transcript, query: "   ").isEmpty)
  }

  @Test func mediaLinesAreNotSearched() throws {
    let transcript = try rows("""
      [
        {"id": 1, "role": "user", "content": "Make a chart"},
        {"id": 2, "role": "assistant", "content": "Here it is.\\nMEDIA:/tmp/walrus-chart.png"}
      ]
      """)
    #expect(ChatFind.hits(in: transcript, query: "walrus").isEmpty)
  }

  // MARK: Order and places

  @Test func newestMatchComesFirstWithOneHitPerMessage() throws {
    let transcript = try rows("""
      [
        {"id": 10, "role": "user", "content": "kiwi one"},
        {"id": 11, "role": "assistant", "content": "kiwi kiwi kiwi"},
        {"id": 12, "role": "user", "content": "no fruit"},
        {"id": 13, "role": "assistant", "content": "kiwi last"}
      ]
      """)
    let hits = ChatFind.hits(in: transcript, query: "kiwi")
    #expect(texts(hits, in: transcript) == ["kiwi last", "kiwi kiwi kiwi", "kiwi one"])
    #expect(hits.map(\.place) == [
      ChatFind.Place(turn: 12, ordinal: 1), ChatFind.Place(turn: 10, ordinal: 1), ChatFind.Place(turn: 10, ordinal: 0),
    ])
  }

  @Test func anOlderMatchIsFoundAgainWhenItsPageLoads() throws {
    let json = """
      [
        {"id": 20, "role": "user", "content": "Plan the trip"},
        {"id": 21, "role": "assistant", "content": "Step one.", "tool_calls": [{"id": "c1", "function": {"name": "terminal"}}]},
        {"id": 22, "role": "tool", "tool_call_id": "c1", "content": "ok"},
        {"id": 23, "role": "assistant", "content": "Pack the **compass**."},
        {"id": 24, "role": "user", "content": "Thanks"}
      ]
      """
    // Read once for the search, and again when the page is loaded: new row ids, same places.
    let searched = try rows(json)
    let loaded = try rows(json)
    let older = try #require(ChatFind.hits(in: searched, query: "compass").first)
    let onScreen = try #require(ChatFind.hits(in: loaded, query: "compass").first)
    #expect(older.row != onScreen.row)
    #expect(older.isSame(as: onScreen))
    #expect(older.place == ChatFind.Place(turn: 20, ordinal: 2))
    #expect(!older.isSame(as: try #require(ChatFind.hits(in: loaded, query: "thanks").first)))
  }

  @Test func messagesWithoutAStoredIDMatchByRow() {
    let sent = TranscriptItem.user("sent from here", timestamp: 1)
    let a = ChatFind.Hit(row: sent.id, place: ChatFind.Place(turn: nil, ordinal: 0))
    let b = ChatFind.Hit(row: UUID(), place: ChatFind.Place(turn: nil, ordinal: 0))
    #expect(a.isSame(as: a))
    #expect(!a.isSame(as: b))
  }

  @Test func aGreetingBeforeTheFirstMessageIsFoundAgainWhenTheStartLoads() throws {
    let json = """
      [
        {"id": 1, "role": "assistant", "content": "Hello, ask me about the **lighthouse**."},
        {"id": 2, "role": "user", "content": "What lighthouse?"},
        {"id": 3, "role": "assistant", "content": "The old one."}
      ]
      """
    let searched = try rows(json)
    let loaded = try rows(json)
    let older = try #require(ChatFind.hits(in: searched, query: "lighthouse").last)
    let onScreen = try #require(ChatFind.hits(in: ChatFind.entries(loaded), query: "lighthouse").last)
    #expect(older.place == ChatFind.Place(turn: nil, ordinal: 1, opensChat: true))
    #expect(older.row != onScreen.row)
    #expect(older.isSame(as: onScreen))
    #expect(!older.isSame(as: try #require(ChatFind.hits(in: loaded, query: "what lighthouse").first)))
    // Rows that do not begin at the chat's start never open it, so they match by row alone.
    let midway = try #require(ChatFind.hits(in: ChatFind.entries(loaded, holdsStart: false), query: "lighthouse").last)
    #expect(!midway.place.opensChat)
    #expect(!older.isSame(as: midway))
  }

  @Test func unnamedTurnRowsNeverMatchAGreeting() {
    // An answer to a message sent from here sits at (no turn, 1), as a greeting does.
    let answer = ChatFind.Hit(row: UUID(), place: ChatFind.Place(turn: nil, ordinal: 1))
    let greeting = ChatFind.Hit(row: UUID(), place: ChatFind.Place(turn: nil, ordinal: 1, opensChat: true))
    #expect(!answer.isSame(as: greeting))
    #expect(!greeting.isSame(as: answer))
  }

  @Test func indexKeepsUpWithAStreamingReply() {
    var index = ChatFind.Index()
    var answer = TranscriptItem(kind: .assistant, text: "Writing about")
    answer.isStreaming = true
    var transcript: [TranscriptRow] = [.user(.user("Tell me", timestamp: 1)), .commentary(answer)]
    #expect(ChatFind.hits(in: index.entries(transcript), query: "otters").isEmpty)
    answer.text += " otters"
    transcript[1] = .commentary(answer)
    #expect(ChatFind.hits(in: index.entries(transcript), query: "otters").count == 1)
  }
}
