import Foundation
import Testing

@testable import HermesKit

/// The running-turn state the transcript and title bar show. The event order is the one a real
/// 0.23 backend sends for a turn that runs a tool (recorded with a probe client).
@Suite struct TurnActivityTests {
  private func event(_ state: inout ChatState, _ type: String, _ payload: JSONValue = [:], at now: Double) {
    state.apply(event: type, payload: payload, now: now)
  }

  @Test func aToolTurnIsWorkingFromStartToFinish() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "run it", timestamp: 99)]
    event(&state, "message.start", at: 100)
    #expect(state.activity == .thinking)
    #expect(state.turnStartedAt == 100)
    event(&state, "thinking.delta", ["text": "(°ロ°) musing..."], at: 100.1)
    event(&state, "thinking.delta", ["text": ""], at: 103)
    event(&state, "tool.start", ["tool_id": "c1", "name": "terminal", "context": "sleep 6"], at: 103)
    guard case .running(let tool) = state.activity else {
      Issue.record("expected a running tool, got \(String(describing: state.activity))")
      return
    }
    #expect(tool.name == "terminal")
    event(&state, "tool.complete", ["tool_id": "c1", "name": "terminal", "duration_s": 6.2, "result": "done"], at: 109)
    #expect(state.activity == .thinking)
    event(&state, "message.delta", ["text": "Done"], at: 112)
    #expect(state.activity == .writing)
    #expect(state.turnStartedAt == 100)
    event(&state, "message.complete", ["text": "Done."], at: 113)
    #expect(state.activity == nil)
    #expect(state.turnStartedAt == nil)
  }

  /// After a reconnect the backend may report no inflight text while a tool runs. The next tool
  /// event alone must bring the working state back.
  @Test func toolEventsAloneMarkTheTurnRunning() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "build it", timestamp: 10)]
    #expect(!state.isStreaming)
    event(&state, "tool.start", ["tool_id": "c2", "name": "terminal"], at: 50)
    #expect(state.isStreaming)
    #expect(state.turnStartedAt == 50)

    var drafting = ChatState()
    event(&drafting, "tool.generating", ["name": "write_file"], at: 60)
    #expect(drafting.isStreaming)
    #expect(drafting.activity == .thinking)
  }

  @Test func anEmptyThinkingLineDoesNotStartATurn() {
    var state = ChatState()
    event(&state, "thinking.delta", ["text": ""], at: 5)
    #expect(!state.isStreaming)
  }

  @Test func resumeSaysRunningEvenWithoutInflightText() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "go", timestamp: 10)]
    state.reconcile(fresh: [TranscriptItem(kind: .user, text: "go", timestamp: 10)], inflight: nil, now: 80)
    #expect(!state.isStreaming)
    state.applyLiveStatus(isRunning: true, startedAt: 12, now: 80)
    #expect(state.isStreaming)
    #expect(state.turnStartedAt == 12)
    #expect(state.activity == .thinking)

    state.applyLiveStatus(isRunning: false, startedAt: nil, now: 81)
    #expect(state.isStreaming, "an idle report is not a reason to end a turn the events say is running")
  }

  @Test func aQuestionWaitingForAnAnswerReadsAsWaiting() {
    var state = ChatState()
    event(&state, "tool.start", ["tool_id": "q", "name": "clarify"], at: 1)
    state.attach(clarify: ServerRequest(rawID: "r1", method: "clarify", params: ["questions": [["question": "Which?"]]]))
    #expect(state.activity == .waiting)
  }

  /// The resumed transcript already holds the user's message; the inflight copy must not repeat it.
  @Test func resumingARunningTurnDoesNotRepeatTheUserMessage() {
    var state = ChatState()
    state.items = TranscriptItem.items(fromHistory: [["role": "user", "text": "Use the terminal", "timestamp": 10]])
    state.applyInflight(["user": "Use the terminal", "assistant": "", "streaming": true], now: 20)
    #expect(state.items.filter { $0.kind == .user }.count == 1)
    #expect(state.isStreaming)
    #expect(state.turnStartedAt == 20)
  }

  /// A long turn posts commentary between tool calls; reopening it mid-turn must not repeat
  /// the message that started it.
  @Test func resumingATurnWithCommentaryDoesNotRepeatTheUserMessage() {
    let history: [JSONValue] = [
      ["role": "user", "text": "Redesign the inbox", "timestamp": 100],
      ["role": "assistant", "text": "Reading the current inbox first.", "timestamp": 110],
      ["role": "tool", "name": "read_file", "tool_call_id": "t1", "timestamp": 111],
      ["role": "assistant", "text": "Builds clean. Screenshotting it.", "timestamp": 300],
    ]
    var withStart = ChatState()
    withStart.items = TranscriptItem.items(fromHistory: history)
    withStart.applyInflight(["user": "Redesign the inbox", "assistant": "", "streaming": true], turnStartedAt: 99, now: 400)
    #expect(withStart.items.filter { $0.kind == .user }.count == 1)

    var withoutStart = ChatState()
    withoutStart.items = TranscriptItem.items(fromHistory: history)
    withoutStart.applyInflight(["user": "Redesign the inbox", "assistant": "", "streaming": true], now: 400)
    #expect(withoutStart.items.filter { $0.kind == .user }.count == 1)
  }

  /// The same words sent again after an answered turn are a new message, shown again.
  @Test func theSameWordsInANewTurnAreShownAgain() {
    var state = ChatState()
    state.items = TranscriptItem.items(fromHistory: [
      ["role": "user", "text": "continue", "timestamp": 100],
      ["role": "tool", "name": "terminal", "tool_call_id": "t1", "timestamp": 110],
      ["role": "assistant", "text": "Done.", "timestamp": 120],
    ])
    state.applyInflight(["user": "continue", "assistant": "", "streaming": true], turnStartedAt: 500, now: 501)
    #expect(state.items.filter { $0.kind == .user }.count == 2)
  }

  @Test func liveSessionReadsRunningAndStart() {
    let live = LiveSession(json: ["session_id": "abc", "running": true, "status": "working", "turn_started_at": 1_794_453_783.6])
    #expect(live.isRunning)
    #expect(live.turnStartedAt == 1_794_453_783.6)
    let idle = LiveSession(json: ["session_id": "abc", "running": false, "status": "idle"])
    #expect(!idle.isRunning)
    let waiting = LiveSession(json: ["session_id": "abc", "status": "waiting"])
    #expect(waiting.isRunning)
  }
}

@Suite struct FileExtractionTests {
  private func tool(_ name: String, args: JSONValue, result: String = "", error: Bool = false) -> TranscriptItem {
    var call = ToolCall(callID: UUID().uuidString, name: name, args: args, isDone: true)
    call.result = result
    call.isError = error
    return .tool(call, timestamp: 50)
  }

  @Test func writeAndPatchCallsNameTheirFiles() {
    let items = [
      tool("write_file", args: ["path": "notes/plan.md", "content": "x"],
           result: #"{"bytes_written": 1, "resolved_path": "/Users/me/proj/notes/plan.md"}"#),
      tool("patch", args: ["mode": "replace", "path": "/Users/me/proj/app.swift", "old_string": "a", "new_string": "b"]),
      tool("patch", args: ["mode": "patch", "patch": "*** Begin Patch\n*** Add File: /tmp/new.txt\n+hi\n*** Update File: /tmp/old.py\n*** Delete File: /tmp/gone.txt\n*** End Patch"]),
    ]
    let files = FileExtraction.files(in: items)
    #expect(files.map(\.path) == ["/Users/me/proj/notes/plan.md", "/Users/me/proj/app.swift", "/tmp/new.txt", "/tmp/old.py"])
    #expect(files.map(\.origin) == [.written, .edited, .written, .edited])
    #expect(files[0].name == "plan.md")
    #expect(files[0].folder == "/Users/me/proj/notes")
    #expect(files[0].kind == .text)
    #expect(files[1].kind == .code)
  }

  @Test func readsAndFailuresAreNotFiles() {
    let items = [
      tool("read_file", args: ["path": "/etc/hosts"], result: #"{"content": "x", "path": "/etc/hosts"}"#),
      tool("write_file", args: ["path": "/tmp/x.txt"], result: "Error: denied", error: true),
    ]
    #expect(FileExtraction.files(in: items).isEmpty)
  }

  @Test func producerToolsReportOutputs() {
    let items = [
      tool("text_to_speech", args: ["text": "hi"], result: #"{"file_path": "/Users/me/.hermes/audio_cache/a.mp3"}"#),
      tool("terminal", args: ["command": "ls"], result: #"{"output": "/Users/me/a.png", "exit_code": 0}"#),
      tool("browser_screenshot", args: [:], result: #"{"screenshot_path": "/Users/me/.hermes/screenshots/s.png"}"#),
    ]
    let files = FileExtraction.files(in: items)
    #expect(files.map(\.path) == ["/Users/me/.hermes/audio_cache/a.mp3", "/Users/me/.hermes/screenshots/s.png"])
    #expect(files.allSatisfy { $0.origin == .delivered })
    #expect(files.map(\.kind) == [.audio, .image])
  }

  @Test func answersDeliverAndMentionFiles() {
    let text = """
      Saved the report to `/Users/me/out/report.pdf`, and the chart is at ~/out/chart.png.
      MEDIA:/Users/me/out/raw-data
      ```sh
      cat /var/log/system.log
      ```
      See https://example.com/a.png and /Users/me/dir/ too. Version 1.2 is fine.
      """
    let files = FileExtraction.files(in: [TranscriptItem(kind: .assistant, text: text, timestamp: 70)])
    #expect(files.map(\.path) == ["/Users/me/out/report.pdf", "~/out/chart.png", "/Users/me/out/raw-data"])
    #expect(files.map(\.origin) == [.mentioned, .mentioned, .delivered])
  }

  @Test func aHomeShorthandAndItsFullPathAreOneFile() {
    let items = [
      tool("write_file", args: ["path": "/Users/me/proj/docs/handoff.md"]),
      TranscriptItem(kind: .assistant, text: "The handoff is at ~/proj/docs/handoff.md.\nMEDIA:/Users/me/proj/docs/handoff.md", timestamp: 80),
    ]
    let files = FileExtraction.files(in: items)
    #expect(files.map(\.path) == ["/Users/me/proj/docs/handoff.md"])
    #expect(files.first?.origin == .written)
  }

  @Test func aPrivateTmpPathAndItsShortFormAreOneFile() {
    let items = [
      tool("write_file", args: ["path": "/private/tmp/a.txt"]),
      TranscriptItem(kind: .assistant, text: "Saved to /tmp/a.txt.", timestamp: 80),
    ]
    let files = FileExtraction.files(in: items)
    #expect(files.map(\.path) == ["/private/tmp/a.txt"])
    #expect(files.first?.origin == .written)
    #expect(!FileExtraction.isAlias("/tmp/a.txt", of: "/private/tmp/b.txt"))
  }

  @Test func mediaLinesLeaveTheShownAnswer() {
    let text = "Done.\nMEDIA:/tmp/a.txt\n```\nMEDIA:/tmp/shown.txt\n```"
    #expect(FileExtraction.hidingMediaLines(text) == "Done.\n```\nMEDIA:/tmp/shown.txt\n```")
    #expect(FileExtraction.hidingMediaLines("No tags here.") == "No tags here.")
  }

  @Test func theStrongestOriginAndLatestTimeWin() {
    var later = TranscriptItem(kind: .assistant, text: "Wrote /tmp/a.txt.", timestamp: 90)
    later.timestamp = 90
    let files = FileExtraction.files(in: [tool("write_file", args: ["path": "/tmp/a.txt"]), later])
    #expect(files.count == 1)
    #expect(files[0].origin == .written)
    #expect(files[0].timestamp == 90)
  }

  @Test func aFinishedTurnListsItsFilesUnderTheAnswer() {
    let user = TranscriptItem(kind: .user, text: "make it", timestamp: 1)
    let write = tool("write_file", args: ["path": "/tmp/made.txt"])
    let answer = TranscriptItem(kind: .assistant, text: "Done: /tmp/made.txt", timestamp: 9)
    let rows = TranscriptLayout.rows(for: [user, write, answer], isStreaming: false)
    #expect(rows.count == 4)
    guard case .files(let turn) = rows.last else {
      Issue.record("expected a files row last")
      return
    }
    #expect(turn.files.map(\.path) == ["/tmp/made.txt"])
    // The row keeps its identity across layouts so the list does not redraw it.
    let again = TranscriptLayout.rows(for: [user, write, answer], isStreaming: false)
    #expect(again.last?.id == rows.last?.id)

    let running = TranscriptLayout.rows(for: [user, write], isStreaming: true)
    #expect(!running.contains { if case .files = $0 { return true } else { return false } })
  }
}
