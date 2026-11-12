import Foundation
import Testing

@testable import HermesKit

/// A chat the desktop app (or any other Hermes process) is running: no events reach this app, so
/// "Working" comes from the heartbeat Hermes writes to the shared session store.
@Suite struct RunningElsewhereTests {
  private func row(description: String, at: Double?) -> SessionSummary {
    var fields: [String: JSONValue] = ["id": "local-abc", "title": "Talaria features", "source": "local"]
    fields["last_activity_description"] = .string(description)
    if let at { fields["last_activity_at"] = .number(at) }
    return SessionSummary(json: .object(fields))
  }

  @Test func aFreshLabelMeansATurnIsRunning() {
    let session = row(description: "receiving stream response", at: 1_000)
    #expect(session.lastActivityAt == 1_000)
    #expect(session.isTurnRunning(now: 1_002))
    #expect(session.isTurnRunning(now: 1_000 + 170))
  }

  @Test func anEmptyLabelMeansTheTurnEnded() {
    // Hermes clears the label in the turn's `finally` and keeps the time.
    #expect(!row(description: "", at: 1_000).isTurnRunning(now: 1_002))
  }

  @Test func anOldLabelIsADeadProcessNotARunningTurn() {
    #expect(!row(description: "executing tool terminal", at: 1_000).isTurnRunning(now: 1_000 + 181))
    #expect(!row(description: "executing tool terminal", at: nil).isTurnRunning(now: 1_000))
  }

  @Test func aClockAheadOfThePhoneStillCounts() {
    #expect(row(description: "executing tool terminal", at: 1_030).isTurnRunning(now: 1_000))
    #expect(!row(description: "executing tool terminal", at: 1_100).isTurnRunning(now: 1_000))
  }

  @Test func theStoredTranscriptSaysWhatTheTurnIsDoing() {
    let user = TranscriptItem(kind: .user, text: "Run the tests", timestamp: 500)
    var call = ToolCall(callID: "c1", name: "terminal", args: ["command": "swift test"], isDone: false)
    #expect(TurnActivity.inferred(from: [user, .tool(call, timestamp: 510)]) == .running(call))

    call.isDone = true
    #expect(TurnActivity.inferred(from: [user, .tool(call, timestamp: 510)]) == .thinking)
    #expect(TurnActivity.inferred(from: [user]) == .thinking)
    #expect(TurnActivity.inferred(from: []) == .thinking)

    let question = ToolCall(callID: "c2", name: "clarify", args: ["question": "Which one?"], isDone: false)
    #expect(TurnActivity.inferred(from: [user, .tool(question, timestamp: 520)]) == .waiting)

    let answer = TranscriptItem(kind: .assistant, text: "Done", timestamp: 530)
    #expect(TurnActivity.turnStart(in: [user, .tool(call, timestamp: 510), answer]) == 500)
    #expect(TurnActivity.turnStart(in: [answer]) == nil)
  }
}
