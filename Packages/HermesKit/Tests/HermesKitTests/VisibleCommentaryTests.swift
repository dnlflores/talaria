import Foundation
import Testing
@testable import HermesKit

@Suite struct VisibleCommentaryTests {
  @Test func assistantWordsNeverBecomeToolLogContent() {
    var note = TranscriptItem(kind: .assistant, text: "I found the cause.")
    note.reasoning = "Compare both paths."
    let answer = TranscriptItem(kind: .assistant, text: "Fixed.")
    let rows = TranscriptLayout.rows(for: [
      .user("Fix it", timestamp: 1), note,
      .tool(ToolCall(callID: "read", name: "read_file", isDone: true)), answer,
    ], isStreaming: false)
    let work = rows.compactMap { row -> WorkLog? in
      if case .work(let log) = row { return log }; return nil
    }
    #expect(work.flatMap(\.items).allSatisfy { $0.text.isEmpty })
    #expect(work.flatMap(\.items).filter { !$0.reasoning.isEmpty }.map(\.reasoning) == ["Compare both paths."])
    #expect(work.reduce(0) { $0 + $1.toolCount } == 1)
    #expect(rows.count == 5) // user, reasoning, commentary, tool log, answer
    guard case .commentary(let visible) = rows[2], case .answer(let final) = rows[4] else {
      Issue.record("expected commentary before tools, then the final answer")
      return
    }
    #expect(visible.text == note.text)
    #expect(final.text == answer.text)
    #expect(Set(rows.map(\.id)).count == rows.count)
    let again = TranscriptLayout.rows(for: [
      .user("Fix it", timestamp: 1), note,
      .tool(ToolCall(callID: "read", name: "read_file", isDone: true)), answer,
    ], isStreaming: false)
    #expect(again[1].id == rows[1].id)
    #expect(again[2].id == rows[2].id)
  }

  @Test func streamingWordsStayVisibleOutsideCollapsedLogs() {
    var state = ChatState()
    state.items = [.user("Check this", timestamp: 1)]
    state.apply(event: "message.delta", payload: ["text": "Checking the file."], now: 2)
    let rows = TranscriptLayout.rows(for: state.items, isStreaming: true)
    #expect(!rows.contains { row in
      if case .work(let log) = row { return log.items.contains { !$0.text.isEmpty } }; return false
    })
    // A pending message is not styled as a final answer and never jumps into a log later.
    #expect(!rows.contains { if case .answer = $0 { return true }; return false })
    #expect(rows.count == 2)
  }
}
