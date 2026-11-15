import Foundation
import Testing

@testable import HermesKit

/// `/btw` and `/bg`: the phone runs them through `prompt.btw` / `prompt.background`, and their
/// answers (`btw.complete`, `background.complete`) become cards that only this device shows.
@Suite struct SideAgentTests {
  private func side(_ typed: String) -> SideCommand? {
    SlashInvocation(typed).flatMap(SideCommand.init)
  }

  @Test func btwAndBackgroundAreNoLongerMacOnly() throws {
    for name in ["/btw", "/bg", "/background", "btw"] {
      #expect(!SlashPolicy.isMacOnly(name), "\(name)")
    }
    let menu = try JSONValue.parse(#"""
      {"replace_from": 1, "items": [
        {"text": "btw", "meta": "Ask a quick side question"},
        {"text": "background", "meta": "Run a prompt in the background"},
        {"text": "skin", "meta": "Theme"}
      ]}
      """#)
    #expect(SlashCompletion.items(from: menu).map(\.name) == ["/btw", "/background"])
  }

  @Test func commandsAreRecognisedWithTheirText() throws {
    let btw = try #require(side("/btw what file were you editing?"))
    #expect(btw.kind == .btw)
    #expect(btw.text == "what file were you editing?")
    #expect(btw.method == "prompt.btw")

    let bg = try #require(side("/BG tidy the notes\nand push"))
    #expect(bg.kind == .background)
    #expect(bg.text == "tidy the notes\nand push")
    #expect(bg.method == "prompt.background")
    #expect(side("/background x")?.kind == .background)

    #expect(side("/usage") == nil)
    #expect(side("/btw")?.text == "")
    #expect(side("/btw")?.usage.contains("without interrupting it") == true)
    #expect(side("/background")?.usage.hasPrefix("Usage: /background <task>") == true)
  }

  @Test func completionPayloadsParse() throws {
    let btw = try #require(SideTask(event: "btw.complete", payload: try JSONValue.parse(
      #"{"task_id": "btw_1a2b3c", "question": "what file?", "text": "**Greeting.swift**"}"#)))
    #expect(btw == SideTask(kind: .btw, taskID: "btw_1a2b3c", prompt: "what file?", answer: "**Greeting.swift**"))
    #expect(!btw.isFailed)
    #expect(btw.shownAnswer == "**Greeting.swift**")

    // `background.complete` carries no question.
    let bg = try #require(SideTask(event: "background.complete", payload: try JSONValue.parse(
      #"{"task_id": "bg_9f8e7d", "text": "Done: 3 notes tidied."}"#)))
    #expect(bg.kind == .background)
    #expect(bg.prompt == "")
    #expect(bg.answer == "Done: 3 notes tidied.")

    let failed = try #require(SideTask(event: "btw.complete", payload: try JSONValue.parse(
      #"{"task_id": "btw_x", "question": "q", "text": "error: workspace_unavailable (cwd: /gone)"}"#)))
    #expect(failed.isFailed)
    #expect(failed.shownAnswer == "workspace_unavailable (cwd: /gone)")

    #expect(SideTask(event: "message.complete", payload: [:]) == nil)
  }

  @Test func aRepeatedDeliveryAddsOneCard() {
    var state = ChatState()
    let payload: JSONValue = ["task_id": "btw_1", "question": "what file?", "text": "Greeting.swift"]
    let first = state.apply(event: "btw.complete", payload: payload, now: 10)
    let again = state.apply(event: "btw.complete", payload: payload, now: 11)
    #expect(state.items.count == 1)
    #expect(state.items[0].kind == .side)
    #expect(state.items[0].isLocal)
    #expect(state.items[0].text == "Greeting.swift")
    #expect(first == [.sideAnswer(state.items[0])])
    #expect(again.isEmpty)

    _ = state.apply(event: "btw.complete", payload: ["task_id": "btw_2", "question": "and?", "text": "That too."], now: 12)
    #expect(state.items.count == 2)
  }

  @Test func aBackgroundAnswerTakesItsTaskFromTheNotice() throws {
    var state = ChatState()
    let command = try #require(side("/bg tidy the notes"))
    var notice = TranscriptItem.sideNotice(command, timestamp: 5)
    notice.side?.taskID = "bg_1"
    state.items.append(notice)
    _ = state.apply(event: "background.complete", payload: ["task_id": "bg_1", "text": "Tidied."], now: 9)
    #expect(state.items.count == 2)
    #expect(state.items[1].side == SideTask(kind: .background, taskID: "bg_1", prompt: "tidy the notes", answer: "Tidied."))
  }

  /// The card lands while the reply streams: the reply goes on, its new steps growing above the card.
  @Test func sideRowsStayBelowARunningReply() throws {
    var state = ChatState()
    state.items.append(.user("Write the release notes", timestamp: 1))
    _ = state.apply(event: "message.start", payload: [:], now: 2)
    _ = state.apply(event: "message.delta", payload: ["text": "First half, "], now: 3)
    let command = try #require(side("/btw what file?"))
    state.items.append(.sideNotice(command, timestamp: 4))
    _ = state.apply(event: "btw.complete", payload: ["task_id": "btw_1", "question": "what file?", "text": "Notes.md"], now: 5)
    #expect(state.activity == .writing)
    _ = state.apply(event: "tool.start", payload: ["tool_id": "t1", "name": "terminal"], now: 5.5)
    _ = state.apply(event: "tool.complete", payload: ["tool_id": "t1", "summary": "done"], now: 5.6)
    _ = state.apply(event: "message.delta", payload: ["text": "second half."], now: 6)
    // While it runs, the reply's newest steps grow above the side rows, which stay last.
    let running = TranscriptLayout.rows(for: state.items, isStreaming: true)
    #expect(running.suffix(2).allSatisfy { if case .side = $0 { return true } else { return false } })
    _ = state.apply(event: "message.complete", payload: ["text": "second half."], now: 7)

    let replies = state.items.filter { $0.kind == .assistant }
    #expect(replies.map(\.text) == ["First half, ", "second half."])
    #expect(replies.allSatisfy { !$0.isStreaming })
    #expect(!state.isStreaming)

    let rows = TranscriptLayout.rows(for: state.items, isStreaming: false)
    let kinds = rows.map { row -> String in
      switch row {
      case .user: "user"
      case .commentary: "commentary"
      case .answer: "answer"
      case .work: "work"
      case .side: "side"
      default: "other"
      }
    }
    #expect(kinds == ["user", "commentary", "work", "answer", "side", "side"])
  }

  /// Text streaming on after a card lands goes into the same message, not a second one.
  @Test func deltasAroundACardStayOneMessage() throws {
    var state = ChatState()
    state.items.append(.user("Write the notes", timestamp: 1))
    _ = state.apply(event: "message.delta", payload: ["text": "First half, "], now: 2)
    _ = state.apply(event: "btw.complete", payload: ["task_id": "btw_1", "question": "q", "text": "A"], now: 3)
    _ = state.apply(event: "message.delta", payload: ["text": "second half."], now: 4)
    _ = state.apply(event: "message.complete", payload: ["text": "First half, second half."], now: 5)
    #expect(state.items.map(\.kind) == [.user, .assistant, .side])
    #expect(state.items[1].text == "First half, second half.")
    #expect(!state.items[1].isStreaming)
    #expect(!state.isStreaming)
  }

  @Test func heldSideItemsComeBackInTimeOrderOnce() throws {
    let command = try #require(side("/btw what file?"))
    let notice = TranscriptItem.sideNotice(command, timestamp: 15)
    let card = TranscriptItem.sideAnswer(SideTask(kind: .btw, taskID: "btw_1", prompt: "what file?", answer: "A"), timestamp: 16)
    var state = ChatState()
    state.items = [
      .user("one", timestamp: 10), TranscriptItem(kind: .assistant, text: "reply one", timestamp: 12),
      .user("two", timestamp: 20), TranscriptItem(kind: .assistant, text: "reply two", timestamp: 22),
    ]
    state.restoreSideItems([notice, card])
    #expect(state.items.map(\.text) == ["one", "reply one", "what file?", "A", "two", "reply two"])
    // Already on screen: nothing added, even as a copy with another identity.
    state.restoreSideItems([notice, card, .sideAnswer(card.side!, timestamp: 30)])
    #expect(state.items.count == 6)
  }
}
