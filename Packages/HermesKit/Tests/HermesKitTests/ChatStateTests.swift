import Foundation
import Testing

@testable import HermesKit

private func event(_ state: inout ChatState, _ type: String, _ payload: JSONValue = [:], at now: Double = 100) -> [ChatState.Effect] {
  state.apply(event: type, payload: payload, now: now)
}

@Suite struct ChatStateEventTests {
  @Test func streamsAReplyTokenByToken() {
    var state = ChatState()
    _ = event(&state, "message.start")
    _ = event(&state, "thinking.delta", ["text": "reading files"])
    #expect(state.status == "reading files")
    _ = event(&state, "message.delta", ["text": "Hel"])
    _ = event(&state, "message.delta", ["text": "lo"])
    #expect(state.items.count == 1)
    #expect(state.items[0].text == "Hello")
    #expect(state.items[0].isStreaming)
    #expect(state.isStreaming)
    #expect(state.status.isEmpty)

    let effects = event(&state, "message.complete", ["text": "Hello.", "usage": ["model": "model-b"]], at: 130)
    #expect(effects == [.sessionsChanged, .turnFinished])
    #expect(state.items[0].text == "Hello.")
    #expect(!state.items[0].isStreaming)
    #expect(state.items[0].timestamp == 130)
    #expect(!state.isStreaming)
    #expect(state.info.model == "model-b")
  }

  @Test func aToolStartDropsAnEmptyStreamAndKeepsAnInterimNote() {
    var state = ChatState()
    _ = event(&state, "message.start")
    _ = event(&state, "tool.start", ["tool_id": "t1", "name": "terminal", "context": "ls"])
    #expect(state.items.map(\.kind) == [.tool])

    _ = event(&state, "tool.complete", ["tool_id": "t1", "name": "terminal", "summary": "listed 3 files", "duration_s": 1.5, "result": "a\nb\nc"])
    #expect(state.items[0].tool?.isDone == true)
    #expect(state.items[0].tool?.duration == 1.5)
    #expect(state.items[0].tool?.result == "a\nb\nc")
    #expect(state.items[0].tool?.isError == false)

    _ = event(&state, "message.delta", ["text": "Now the tests."])
    _ = event(&state, "tool.start", ["tool_id": 7, "name": "terminal"])
    #expect(state.items.map(\.kind) == [.tool, .assistant, .tool])
    #expect(!state.items[1].isStreaming)
    #expect(state.items[2].tool?.callID == "7")
  }

  @Test func toolErrorsAreReadFromTheSummary() {
    var state = ChatState()
    _ = event(&state, "tool.start", ["tool_id": "a", "name": "patch"])
    _ = event(&state, "tool.complete", ["tool_id": "a", "summary": "Error: no match", "inline_diff": "+x"])
    #expect(state.items[0].tool?.isError == true)
    #expect(state.items[0].tool?.inlineDiff == "+x")

    _ = event(&state, "tool.start", ["tool_id": "b", "name": "terminal"])
    _ = event(&state, "tool.complete", ["tool_id": "b", "summary": "ran with no errors"])
    #expect(state.items[1].tool?.isError == false)
  }

  @Test func aCompletionWithoutAStartStillShowsTheTool() {
    var state = ChatState()
    _ = event(&state, "tool.complete", ["tool_id": "x", "name": "web_search", "summary": "3 results"])
    #expect(state.items.count == 1)
    #expect(state.items[0].tool?.name == "web_search")
    #expect(state.items[0].tool?.isDone == true)
  }

  @Test func aFinalTextWithoutAStreamIsAppendedOnce() {
    var state = ChatState()
    _ = event(&state, "message.complete", ["text": "Done."])
    _ = event(&state, "message.complete", ["text": "Done."])
    #expect(state.items.map(\.text) == ["Done."])
  }

  @Test func sessionInfoAndTitleMerge() {
    var state = ChatState()
    _ = event(&state, "session.info", ["model": "m1", "cwd": "/work", "reasoning_effort": "high", "running": true])
    _ = event(&state, "session.info", ["model": "", "branch": "main"])
    _ = event(&state, "session.title", ["title": "Fix the build"])
    #expect(state.info.model == "m1")
    #expect(state.info.cwd == "/work")
    #expect(state.info.branch == "main")
    #expect(state.info.reasoningEffort == "high")
    #expect(state.info.isRunning)
    #expect(state.title == "Fix the build")
  }

  @Test func aRefusedTurnGivesTheWordsBack() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .assistant, text: "earlier"), TranscriptItem(kind: .user, text: "try this")]
    _ = event(&state, "message.start")
    let effects = event(&state, "error", ["message": "This chat is open in another Hermes window (opened by desktop)"])
    #expect(effects == [.refused(message: "This chat is open in another Hermes window (opened by desktop)", text: "try this")])
    #expect(state.items.map(\.text) == ["earlier"])
    #expect(!state.isStreaming)
  }

  @Test func otherErrorsStopTheStreamAndReport() {
    var state = ChatState()
    _ = event(&state, "message.delta", ["text": "partial"])
    let effects = event(&state, "turn.error", ["message": "provider overloaded"])
    #expect(effects == [.failure("provider overloaded")])
    #expect(state.items[0].text == "partial")
    #expect(!state.items[0].isStreaming)
    #expect(!state.isStreaming)
  }

  @Test func idleEventsEndTheTurn() {
    var state = ChatState()
    _ = event(&state, "message.delta", ["text": "x"])
    _ = event(&state, "session.idle")
    #expect(!state.isStreaming)
    #expect(event(&state, "notice", ["text": "Compressed context"]) == [.notice("Compressed context")])
    #expect(event(&state, "something.unknown", ["a": 1]).isEmpty)
  }
}

@Suite struct ChatStateReconcileTests {
  private func history(_ pairs: [(String, String)]) -> [TranscriptItem] {
    TranscriptItem.items(fromHistory: pairs.map { ["role": .string($0.0), "text": .string($0.1), "timestamp": 10] })
  }

  @Test func aLongerCopyOnlyAppendsItsTail() {
    var state = ChatState()
    state.items = history([("user", "hi"), ("assistant", "hello")])
    let before = state.items.map(\.id)
    state.reconcile(fresh: history([("user", "hi"), ("assistant", "hello"), ("user", "more"), ("assistant", "sure")]), inflight: nil, now: 50)
    #expect(Array(state.items.map(\.id).prefix(2)) == before)
    #expect(state.items.map(\.text) == ["hi", "hello", "more", "sure"])
    #expect(!state.isStreaming)
  }

  @Test func aPendingMessageThatLandedIsNotDuplicated() {
    var state = ChatState()
    state.items = history([("user", "hi"), ("assistant", "hello")])
    var mine = TranscriptItem(kind: .user, text: "run   the tests", timestamp: 40)
    mine.isPending = true
    state.items.append(mine)
    state.reconcile(fresh: history([("user", "hi"), ("assistant", "hello"), ("user", "run the tests")]), inflight: ["streaming": true], now: 50)
    #expect(state.items.filter { $0.kind == .user }.map(\.text) == ["hi", "run   the tests"])
    #expect(state.items.first { $0.id == mine.id }?.hasLanded == true)
    #expect(state.items.last?.kind == .assistant)
    #expect(state.items.last?.isStreaming == true)
    #expect(state.isStreaming)
  }

  @Test func aDivergedTranscriptIsReplacedOnce() {
    var state = ChatState()
    state.items = history([("user", "hi"), ("assistant", "hello"), ("user", "undo me"), ("assistant", "ok")])
    var typed = TranscriptItem(kind: .user, text: "still typing")
    typed.isPending = true
    state.items.append(typed)
    state.reconcile(fresh: history([("user", "hi"), ("assistant", "hello")]), inflight: nil, now: 50)
    #expect(state.items.map(\.text) == ["hi", "hello", "still typing"])
  }

  @Test func theStaleStreamIsDroppedBeforeComparing() {
    var state = ChatState()
    state.items = history([("user", "hi")])
    _ = state.apply(event: "message.delta", payload: ["text": "half an ans"], now: 20)
    state.reconcile(fresh: history([("user", "hi"), ("assistant", "half an answer, finished")]), inflight: nil, now: 50)
    #expect(state.items.map(\.text) == ["hi", "half an answer, finished"])
  }

  @Test func toolsFinishedElsewhereCompleteInPlace() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "go"), .tool(ToolCall(callID: "c1", name: "terminal"))]
    var done = ToolCall(callID: "c1", name: "terminal", isDone: true)
    done.result = "ok"
    state.reconcile(fresh: [TranscriptItem(kind: .user, text: "go"), .tool(done)], inflight: nil, now: 50)
    #expect(state.items.count == 2)
    #expect(state.items[1].tool?.isDone == true)
    #expect(state.items[1].tool?.result == "ok")
  }

  @Test func inflightOnFirstLoadShowsTheRunningTurn() {
    var state = ChatState()
    state.items = history([("user", "yes"), ("assistant", "done")])
    state.applyInflight(["user": "yes", "assistant": "Working on", "streaming": true], now: 60)
    #expect(state.items.map(\.text) == ["yes", "done", "yes", "Working on"])
    #expect(state.isStreaming)
  }
}

@Suite struct ClarifyTests {
  private func request(_ id: JSONValue = "r1", questions: JSONValue) -> ServerRequest {
    ServerRequest(rawID: id, method: "clarify", params: ["session_id": "live1", "questions": questions])
  }

  @Test func aRequestAttachesToItsRunningToolRow() {
    var state = ChatState()
    _ = state.apply(event: "tool.start", payload: ["tool_id": "c9", "name": "clarify", "args": ["questions": [["question": "Which one?", "choices": ["A", "B"]]]]], now: 1)
    state.attach(clarify: request(questions: [["qid": "q0", "question": "which one? ", "choices": ["A", "B"]]]))
    #expect(state.items.count == 1)
    #expect(state.items[0].tool?.pendingRequest?.id == "r1")
    #expect(state.items[0].tool?.questions.first?.qid == "q0")

    state.attach(clarify: request(questions: [["qid": "q0", "question": "which one?"]]))
    #expect(state.items.count == 1)
  }

  @Test func aRequestWithNoRowCreatesOne() {
    var state = ChatState()
    state.attach(clarify: request(42, questions: [["question": "Proceed?", "choices": ["Yes", "No"]]]))
    #expect(state.items.count == 1)
    #expect(state.items[0].tool?.callID == "ask-42")
    #expect(state.items[0].tool?.questions.first?.choices == ["Yes", "No"])
  }

  @Test func answersBecomeTheWireResult() throws {
    var state = ChatState()
    state.attach(clarify: request(questions: [
      ["qid": "a", "question": "Pick one", "choices": ["X", "Y"]],
      ["qid": "b", "question": "Pick many", "choices": ["1", "2"], "multi_select": true],
      ["qid": "c", "question": "Anything else?"],
    ]))
    let outcome = state.answer(clarifyRequestID: "r1", values: [["Y"], ["1", "2"], nil])
    let answered = try #require(outcome)
    #expect(answered.request.id == "r1")
    #expect(answered.result["answers"]["a"] == .string("Y"))
    #expect(answered.result["answers"]["b"] == .array(["1", "2"]))
    #expect(answered.result["answers"]["c"].isNull)
    let tool = try #require(state.items[0].tool)
    #expect(tool.pendingRequest == nil)
    #expect(tool.answers?.map(\.skipped) == [false, false, true])
    #expect(tool.questions.count == 3)
  }

  @Test func aWithdrawnRequestIsMarkedCancelled() {
    var state = ChatState()
    state.attach(clarify: request(questions: [["question": "Still there?"]]))
    let effects = state.apply(event: "request.cancel", payload: ["id": "r1"], now: 5)
    #expect(effects == [.requestCancelled("r1")])
    #expect(state.items[0].tool?.pendingRequest == nil)
    #expect(state.items[0].tool?.isCancelled == true)
  }

  @Test func storedAnswersParseAcrossFormats() {
    let responses = ClarifyAnswer.parse(#"{"responses":[{"question":"Q1","user_response":"Blue","status":"answered"},{"question":"Q2","user_response":null,"status":"skipped"}]}"#, questionCount: 2)
    #expect(responses == [ClarifyAnswer(values: ["Blue"], skipped: false, question: "Q1"), ClarifyAnswer(values: [], skipped: true, question: "Q2")])
    #expect(ClarifyAnswer.parse(#"[clarify] user responded: "Use the second option""#, questionCount: 1)?.first?.values == ["Use the second option"])
    #expect(ClarifyAnswer.parse("The user skipped the question.", questionCount: 2)?.map(\.skipped) == [true, true])
    #expect(ClarifyAnswer.parse(#"{"answers":{"0":["a","b"]}}"#, questionCount: 1)?.first?.values == ["a", "b"])
    #expect(ClarifyAnswer.parse("  ", questionCount: 1) == nil)
  }
}
