import Foundation
import Testing

@testable import HermesKit

@Suite struct CommentaryReconcileTests {
  private func streamedToolTurn() -> ChatState {
    var state = ChatState()
    state.items = [.user("Check this", timestamp: 1)]
    state.apply(event: "message.delta", payload: ["text": "Checking the file."], now: 2)
    state.apply(event: "message.interim", payload: ["text": "Checking the file."], now: 3)
    state.apply(event: "tool.start", payload: ["tool_id": "read", "name": "read_file"], now: 4)
    state.apply(event: "tool.complete", payload: ["tool_id": "read", "result": "ok"], now: 5)
    return state
  }

  private func storedToolTurn() -> [TranscriptItem] {
    TranscriptItem.items(fromStoredRows: [
      ["role": "user", "content": "Check this", "timestamp": 1],
      ["role": "assistant", "content": "", "display_content": "", "display_commentary": ["Checking the file."],
        "tool_calls": [["id": "read", "function": ["name": "read_file", "arguments": "{}"]]]],
      ["role": "tool", "tool_call_id": "read", "content": "ok"],
    ])
  }

  @Test(arguments: [false, true])
  func tailReconcileUpdatesCommentaryInAlignedOverlap(pageReachesBeforeHeld: Bool) {
    var state = streamedToolTurn()
    let older = [TranscriptItem.user("Earlier", timestamp: 0.5), TranscriptItem(kind: .assistant, text: "Earlier answer")]
    if !pageReachesBeforeHeld { state.items.insert(contentsOf: older, at: 0) }
    let before = state.items
    let fresh = (pageReachesBeforeHeld ? older : []) + storedToolTurn()

    let folded = state.reconcileTail(fresh: fresh, inflight: .null, now: 10)
    #expect(folded)

    #expect(state.items.map(\.id) == before.map(\.id))
    var expected = before
    let commentaryIndex = pageReachesBeforeHeld ? 1 : 3
    expected[commentaryIndex].isCommentary = true
    #expect(state.items == expected)
    let rows = TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming)
    #expect(rows.contains { if case .commentary(let item) = $0 { return item.id == before[commentaryIndex].id }; return false })
    #expect(!rows.contains { if case .answer(let item) = $0 { return item.id == before[commentaryIndex].id }; return false })
  }

  @Test(arguments: [false, true])
  func matchedOccurrencesUseAuthoritativeFlagsWithoutTouchingLocalOrPendingItems(tail: Bool) {
    var state = ChatState()
    let older = TranscriptItem.user("Earlier", timestamp: 1)
    var outsidePage = TranscriptItem(kind: .assistant, text: "Same words", timestamp: 2)
    outsidePage.isCommentary = true
    let user = TranscriptItem.user("Current", timestamp: 3)
    var local = TranscriptItem(kind: .assistant, text: "Same words", timestamp: 4)
    local.isLocal = true
    var first = TranscriptItem(kind: .assistant, text: "Same words", timestamp: 5)
    first.reasoning = "Keep live metadata"
    var pending = TranscriptItem.user("Queued", timestamp: 6)
    pending.isPending = true
    var second = TranscriptItem(kind: .assistant, text: "Same words", timestamp: 7)
    second.isCommentary = true
    state.items = [older, outsidePage, user, local, first, pending, second]
    let before = state.items
    var projectedFirst = TranscriptItem(kind: .assistant, text: "Same words")
    projectedFirst.isCommentary = true
    let projectedSecond = TranscriptItem(kind: .assistant, text: "Same words")
    let answer = TranscriptItem(kind: .assistant, text: "Final answer")
    let page = [TranscriptItem.user("Current", timestamp: 3), projectedFirst, projectedSecond, answer]
    let fresh = tail ? page : [TranscriptItem.user("Earlier", timestamp: 1), outsidePage] + page

    if tail {
      let folded = state.reconcileTail(fresh: fresh, inflight: .null, now: 10)
      #expect(folded)
    } else {
      state.reconcile(fresh: fresh, inflight: .null, now: 10)
    }

    var expected = before
    expected[4].isCommentary = true
    expected[6].isCommentary = false
    expected.append(answer)
    #expect(state.items == expected)
  }

  @Test(arguments: [false, true])
  func commentaryUpdatePreservesPendingAndInflightBehavior(tail: Bool) {
    var state = streamedToolTurn()
    var pending = TranscriptItem.user("Queued", timestamp: 6)
    pending.isPending = true
    state.items.append(pending)
    let before = state.items
    state.apply(event: "message.delta", payload: ["text": "Stale partial"], now: 7)
    let inflight: JSONValue = ["assistant": "Fresh partial", "streaming": true]

    if tail {
      let folded = state.reconcileTail(fresh: storedToolTurn(), inflight: inflight, now: 10)
      #expect(folded)
    } else {
      state.reconcile(fresh: storedToolTurn(), inflight: inflight, now: 10)
    }

    var expected = before
    expected[1].isCommentary = true
    #expect(Array(state.items.dropLast()) == expected)
    #expect(state.items.last?.text == "Fresh partial")
    #expect(state.items.last?.isStreaming == true)
    #expect(state.isStreaming)
  }

  @Test func fullReconcileUpdatesCommentaryWithoutReplacingStreamedItems() {
    var state = streamedToolTurn()
    let before = state.items
    let fresh = storedToolTurn()
    #expect(before.map(\.signature) == fresh.map(\.signature))
    #expect(fresh[1].isCommentary)

    state.reconcile(fresh: fresh, inflight: .null, now: 10)

    #expect(state.items.map(\.id) == before.map(\.id))
    var expected = before
    expected[1].isCommentary = true
    #expect(state.items == expected)
    let rows = TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming)
    #expect(rows.count == 3)
    #expect(rows.contains { if case .commentary(let item) = $0 { return item.id == before[1].id }; return false })
    #expect(!rows.contains { if case .answer = $0 { return true }; return false })
  }
}
