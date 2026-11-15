import Foundation
import Testing

@testable import HermesKit

/// Try again: which stored message it goes back to, which words it sends again, and how the Mac's
/// rewind receipt reads.
struct RetryTurnTests {
  private func rows(_ json: String) throws -> [JSONValue] {
    try JSONValue.parse(json).array ?? []
  }

  // MARK: Picking the message

  @Test func picksTheNewestMessageFromThePerson() throws {
    let snapshot = try rows("""
      [
        {"role": "user", "content": "First question", "row_id": 10},
        {"role": "assistant", "content": "First answer", "row_id": 11},
        {"role": "user", "content": "Second question", "row_id": 12},
        {"role": "assistant", "content": "", "row_id": 13, "tool_calls": [{"id": "c1"}]},
        {"role": "tool", "content": "ok", "row_id": 14, "tool_call_id": "c1"},
        {"role": "assistant", "content": "Second answer", "row_id": 15}
      ]
      """)
    #expect(RetryTurn.pick(from: snapshot) == .target(rowID: 12, text: "Second question"))
  }

  @Test func skipsNoticesAndCompactionRows() throws {
    let snapshot = try rows("""
      [
        {"role": "user", "content": "Fix the build", "row_id": 3},
        {"role": "assistant", "content": "Fixed.", "row_id": 4},
        {"role": "user", "content": "Background process finished", "display_kind": "process_complete", "row_id": 5},
        {"role": "user", "content": "Model switched to Opus", "display_kind": "model_switch", "row_id": 6},
        {"role": "user", "content": "[CONTEXT COMPACTION] Earlier turns were summarized", "row_id": 7},
        {"role": "user", "content": "An archived ask", "archived": true, "row_id": 8},
        {"role": "user", "content": "Has no durable id"},
        {"role": "user", "content": "A string id", "row_id": "9"}
      ]
      """)
    #expect(RetryTurn.pick(from: snapshot) == .target(rowID: 3, text: "Fix the build"))
  }

  @Test func aSteerTheyTypedCounts() throws {
    let snapshot = try rows("""
      [
        {"role": "user", "content": "Start", "row_id": 1},
        {"role": "user", "content": "Also check the tests", "display_kind": "steer", "row_id": 2}
      ]
      """)
    #expect(RetryTurn.pick(from: snapshot) == .target(rowID: 2, text: "Also check the tests"))
  }

  @Test func nothingToGoBackTo() throws {
    #expect(RetryTurn.pick(from: []) == .nothing)
    let onlyNotices = try rows("""
      [{"role": "assistant", "content": "Hello", "row_id": 1},
       {"role": "user", "content": "Process finished", "display_kind": "process_complete", "row_id": 2}]
      """)
    #expect(RetryTurn.pick(from: onlyNotices) == .nothing)
    let blank = try rows(#"[{"role": "user", "content": "   ", "row_id": 4}]"#)
    #expect(RetryTurn.pick(from: blank) == .nothing)
  }

  @Test func picturesAndUnknownPartsCannotBeSentAgain() throws {
    let picture = try rows(#"[{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "x"}}], "row_id": 4}]"#)
    #expect(RetryTurn.pick(from: picture) == .unsupported)
    let stored = try rows(#"[{"role": "user", "content": "What is this?\n@image:/tmp/a.jpg\n[screenshot]", "row_id": 5}]"#)
    #expect(RetryTurn.pick(from: stored) == .unsupported)
    let attached = try rows(#"[{"role": "user", "content": "Look\n\n[Image attached at: /tmp/b.png]\n[screenshot]", "row_id": 6}]"#)
    #expect(RetryTurn.pick(from: attached) == .unsupported)
  }

  // MARK: The words sent again

  @Test func textReadsLosslessly() throws {
    #expect(RetryTurn.text(.string("Hello there")) == "Hello there")
    #expect(RetryTurn.text(try JSONValue.parse(#"[{"type": "text", "text": "Hel"}, {"type": "input_text", "text": "lo"}, "!"]"#)) == "Hello!")
    #expect(RetryTurn.text(.string("  \n ")) == "")
    #expect(RetryTurn.text(.array([])) == "")
    // Annotated text, media and anything unknown fail closed.
    #expect(RetryTurn.text(try JSONValue.parse(#"[{"type": "text", "text": "Hi", "cache_control": {}}]"#)) == nil)
    #expect(RetryTurn.text(try JSONValue.parse(#"[{"type": "input_image", "image_url": "x"}]"#)) == nil)
    #expect(RetryTurn.text(.null) == nil)
    #expect(RetryTurn.text(.number(3)) == nil)
  }

  @Test func aSkillTurnShowsItsInvocation() {
    let expanded = """
      [IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions. \
      The full skill content is loaded below.]

      # Work

      The user has provided the following instruction alongside the skill invocation: fix the leak
      """
    #expect(RetryTurn.display(for: expanded) == "/work fix the leak")
    #expect(RetryTurn.display(for: "plain words") == nil)
  }

  // MARK: The rewind receipt

  @Test func receiptReadsWhatCameOff() throws {
    let receipt = RewindReceipt(try JSONValue.parse("""
      {"rewound_count": 4, "target_message": {"id": 12, "content": "Second question", "timestamp": 1794768000.5},
       "new_head_id": 11, "revision": 9}
      """))
    #expect(receipt.didRewind)
    #expect(receipt.rewoundCount == 4)
    #expect(receipt.targetID == 12)
    #expect(receipt.retryText == "Second question")
    #expect(receipt.targetTimestamp == 1794768000.5)
  }

  @Test func receiptSaysNothingWasCut() throws {
    let nothing = RewindReceipt(try JSONValue.parse(#"{"session_id": "s", "status": "nothing", "rewound_count": 0}"#))
    #expect(!nothing.didRewind)
    #expect(nothing.targetID == nil)
    let zero = RewindReceipt(try JSONValue.parse(#"{"rewound_count": 0, "target_message": null}"#))
    #expect(!zero.didRewind)
    let nested = RewindReceipt(try JSONValue.parse(#"{"result": {"rewound_count": 2, "target_message": {"id": 3, "content": "Hi"}}}"#))
    #expect(nested.didRewind)
    #expect(nested.retryText == "Hi")
  }

  // MARK: What the transcript offers it on

  @Test func offeredOnTheNewestMessageAndItsReply() {
    let first = TranscriptItem.user("One", timestamp: 1)
    let firstReply = TranscriptItem(kind: .assistant, text: "Reply one")
    let second = TranscriptItem.user("Two", timestamp: 2)
    let tool = TranscriptItem.tool(ToolCall(callID: "t", name: "read_file", isDone: true))
    let reply = TranscriptItem(kind: .assistant, text: "Reply two")
    let notice = TranscriptItem.slashNotice("ok", command: "/usage", timestamp: 3)
    let offered = RetryTurn.offeredItems(in: [first, firstReply, second, tool, reply, notice])
    #expect(offered == [second.id, reply.id])

    // A turn that failed before any reply: only the message.
    #expect(RetryTurn.offeredItems(in: [first, firstReply, second]) == [second.id])

    // A message still on its way, or one that failed to go: nothing.
    var pending = TranscriptItem.outgoing("Three", shown: nil, timestamp: 4)
    #expect(RetryTurn.offeredItems(in: [first, firstReply, pending]).isEmpty)
    pending.isPending = false
    pending.isFailed = true
    #expect(RetryTurn.offeredItems(in: [first, firstReply, pending]).isEmpty)
  }

  @Test func theViewMustShowTheSameTurnAsTheMac() throws {
    let items = [TranscriptItem.user("Earlier", timestamp: 1), TranscriptItem.user("Fix   the\nbuild", timestamp: 2)]
    let same = try JSONValue.parse(#"{"role": "user", "content": "Fix the build", "row_id": 5}"#)
    let other = try JSONValue.parse(#"{"role": "user", "content": "Sent from the Mac", "row_id": 7}"#)
    #expect(RetryTurn.showsSameTurn(items, as: same))
    #expect(!RetryTurn.showsSameTurn(items, as: other))
    #expect(!RetryTurn.showsSameTurn([], as: same))
  }

  @Test func cutDropsTheTurnTakenBack() {
    let first = TranscriptItem.user("One", timestamp: 1)
    let firstReply = TranscriptItem(kind: .assistant, text: "Reply one")
    let second = TranscriptItem.user("Two", timestamp: 2)
    let reply = TranscriptItem(kind: .assistant, text: "Reply two")
    #expect(RetryTurn.cut([first, firstReply, second, reply], text: "Two").map(\.id) == [first.id, firstReply.id])
    // A view whose newest message reads differently is left for the reload to correct.
    #expect(RetryTurn.cut([first, firstReply, second, reply], text: "Other").count == 4)
  }
}
