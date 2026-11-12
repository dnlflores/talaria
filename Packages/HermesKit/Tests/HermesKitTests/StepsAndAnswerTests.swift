import Foundation
import Testing

@testable import HermesKit

/// Text a running turn writes stays with its steps until the turn ends, so nothing shown as the
/// answer ever jumps into the steps. Recorded from a real Claude turn: two notes, each followed
/// by a terminal call, then the answer.
@Suite struct StepsAndAnswerTests {
  private let user = "Do these steps in order."

  private func rowKinds(_ state: ChatState) -> [String] {
    TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming).map { row in
      switch row {
      case .user: return "user"
      case .answer(let item): return "answer(\(item.text))"
      case .work(let log): return "work(\(log.items.count)\(log.isLive ? ",live" : ""))"
      case .question: return "question"
      case .system: return "system"
      case .files: return "files"
      }
    }
  }

  @Test func textBeingWrittenIsAStepUntilTheTurnEnds() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: user, timestamp: 0)]
    state.apply(event: "message.start", payload: [:], now: 1)
    state.apply(event: "message.delta", payload: ["text": "I'll check the clock first."], now: 2)
    #expect(rowKinds(state) == ["user", "work(1,live)"])
    #expect(state.activity == .writing)

    state.apply(event: "message.complete", payload: ["text": "I'll check the clock first."], now: 3)
    #expect(rowKinds(state) == ["user", "answer(I'll check the clock first.)"])
  }

  @Test func draftingAToolCallSettlesTheNoteAndSaysWhatIsBeingPrepared() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: user, timestamp: 0)]
    state.apply(event: "message.start", payload: [:], now: 1)
    state.apply(event: "message.delta", payload: ["text": "I'll check the clock first."], now: 2)
    state.apply(event: "tool.generating", payload: ["name": "mcp__write_file"], now: 3)
    #expect(state.items.last?.isStreaming == false)
    #expect(state.preparingTool == "write_file")
    guard case .running(let call)? = state.activity else {
      Issue.record("expected a running activity")
      return
    }
    #expect(call.name == "write_file")

    // The interim seal that follows replaces the settled note instead of repeating it.
    state.apply(event: "message.interim", payload: ["text": "I'll check the clock first.", "already_streamed": true], now: 4)
    #expect(state.items.filter { $0.kind == .assistant }.count == 1)

    state.apply(event: "tool.start", payload: ["tool_id": "t1", "name": "write_file", "args": ["path": "/tmp/a"]], now: 5)
    #expect(state.preparingTool == nil)
    #expect(rowKinds(state) == ["user", "work(2,live)"])
  }

  @Test func aNoteThatWasNeverStreamedIsAddedOnce() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: user, timestamp: 0)]
    state.apply(event: "message.start", payload: [:], now: 1)
    state.apply(event: "message.interim", payload: ["text": "I will check the clock.", "already_streamed": false], now: 2)
    state.apply(event: "tool.start", payload: ["tool_id": "t1", "name": "terminal"], now: 3)
    state.apply(event: "tool.complete", payload: ["tool_id": "t1", "name": "terminal", "result": "one"], now: 4)
    state.apply(event: "message.interim", payload: ["text": "It printed one.", "already_streamed": false], now: 5)
    #expect(state.items.filter { $0.kind == .assistant }.map(\.text) == ["I will check the clock.", "It printed one."])
  }

  /// `session.resume` mid-turn: the history holds the notes, and `inflight.assistant` repeats
  /// them all joined together. Only text after them is still being written.
  @Test func reopeningARunningTurnDoesNotRepeatItsNotes() {
    let history: [JSONValue] = [
      ["role": "user", "text": .string(user), "timestamp": 100],
      ["role": "assistant", "text": "I'll check the clock first.", "timestamp": 103],
      ["role": "tool", "name": "terminal", "context": "sleep 3 + 1 command", "tool_call_id": "t1", "timestamp": 106],
      ["role": "assistant", "text": "It printed \"one\".", "timestamp": 109],
    ]
    var state = ChatState()
    state.items = TranscriptItem.items(fromHistory: history)
    state.applyInflight(
      ["user": .string(user), "assistant": "I'll check the clock first.\n\nIt printed \"one\".", "streaming": true],
      turnStartedAt: 100, now: 112)
    #expect(state.items.filter { !$0.text.isEmpty && $0.kind == .assistant }.count == 2)
    #expect(rowKinds(state) == ["user", "work(3,live)"])

    var writing = ChatState()
    writing.items = TranscriptItem.items(fromHistory: history)
    writing.applyInflight(
      ["user": .string(user), "assistant": "I'll check the clock first.\n\nIt printed \"one\".\n\nBoth outputs are", "streaming": true],
      turnStartedAt: 100, now: 112)
    #expect(writing.items.last?.text == "Both outputs are")
    #expect(writing.items.last?.isStreaming == true)
  }

  @Test func unsettledTextSurvivesNotesThatDoNotLineUp() {
    #expect(ChatState.unsettledText("A.\n\nB.\n\nC", settled: ["A.", "B."]) == "C")
    #expect(ChatState.unsettledText("A.B.", settled: ["A.", "B."]) == "")
    #expect(ChatState.unsettledText("intro A. then C", settled: ["A."]) == "then C")
    #expect(ChatState.unsettledText("C only", settled: ["missing"]) == "C only")
    #expect(ChatState.unsettledText("", settled: ["A."]) == "")
  }

  /// A chat opened while a tool runs reads its stored rows, which name the call as soon as it
  /// starts: it shows running, the inflight text is not repeated, and the next event finds it.
  @Test func aToolRunningWhenTheChatIsReopenedIsShownRunning() {
    var state = ChatState()
    state.items = TranscriptItem.items(fromStoredRows: [
      ["id": 1, "role": "user", "content": .string(user), "timestamp": 100],
      ["id": 2, "role": "assistant", "content": "It printed \"one\".", "timestamp": 109,
       "tool_calls": [["id": "t2", "function": ["name": "terminal", "arguments": "{\"command\": \"sleep 14; echo two\"}"]]]],
    ])
    state.applyInflight(["user": .string(user), "assistant": "It printed \"one\".", "streaming": true], turnStartedAt: 100, now: 112)
    #expect(state.items.filter { $0.kind == .user }.count == 1)
    guard case .running(let call)? = state.activity else {
      Issue.record("expected the stored call to be running")
      return
    }
    #expect(call.callID == "t2")
    state.apply(event: "tool.complete", payload: ["tool_id": "t2", "name": "terminal", "result": "two"], now: 120)
    #expect(state.items.filter { $0.tool != nil }.count == 1)
    #expect(state.activity == .thinking)
  }

  @Test func aCallFromStoredRowsStillSaysWhatItRuns() {
    #expect(ToolCall(callID: "a", name: "terminal", args: ["command": "sleep 20; echo heron\nmore"]).preview == "sleep 20; echo heron")
    #expect(ToolCall(callID: "b", name: "terminal", context: "sleep 20 + 1 command", args: ["command": "x"]).preview == "sleep 20 + 1 command")
    #expect(ToolCall(callID: "c", name: "read_file", args: ["path": "/tmp/a.txt"]).preview == "/tmp/a.txt")
    #expect(ToolCall(callID: "d", name: "x").preview == "")
  }

  @Test func toolNamesFromDraftsMatchTheRestOfTheStream() {
    #expect(ToolCall.displayName("mcp__terminal") == "terminal")
    #expect(ToolCall.displayName("terminal") == "terminal")
    #expect(ToolCall.displayName("mcp__grafana__query") == "mcp__grafana__query")
    #expect(ToolCall.displayName("") == "tool")
  }
}
