import Foundation
import Testing

@testable import HermesKit

/// Pictures in a message arrive as `@image:` lines; the app shows the pictures, not the paths.
/// The shapes below are copied from real rows in the session store and from `session.resume`.
@Suite struct ImageContentTests {
  @Test func captionAndPicturesSplitAndThePlaceholderGoes() {
    // A TUI message: words, the reference, and the store's stand-in for the inline picture.
    let raw = "Can we fix the header?\n@image:/Users/me/.hermes/images/upload_k3m9.jpg\n[screenshot]"
    let content = UserContent(raw)
    #expect(content.text == "Can we fix the header?")
    #expect(content.images == ["/Users/me/.hermes/images/upload_k3m9.jpg"])
  }

  @Test func onlyPicturesLeavesNoText() {
    let raw = (1...3).map { "@image:/Users/me/.hermes/images/upload_\($0).jpg" }.joined(separator: "\n")
      + "\n[screenshot]\n[screenshot]\n[screenshot]"
    let content = UserContent(raw)
    #expect(content.text.isEmpty)
    #expect(content.images.count == 3)
  }

  @Test func quotedPathsWithSpacesAndRepeatsCountOnce() {
    let raw = "Look\n@image:`/Users/me/My Shots/a b.png`\n@image:\"/tmp/c.png\"\n@image:/tmp/c.png"
    #expect(UserContent(raw).images == ["/Users/me/My Shots/a b.png", "/tmp/c.png"])
  }

  @Test func typedPlaceholderStaysWhenNothingWasAttached() {
    #expect(UserContent("Why does it say [screenshot] here?\n[screenshot]").text == "Why does it say [screenshot] here?\n[screenshot]")
  }

  @Test func referenceInsideACodeBlockIsText() {
    let raw = "The format is:\n```\n@image:/path/to/file.png\n```"
    let content = UserContent(raw)
    #expect(content.images.isEmpty)
    #expect(content.text == raw)
  }

  @Test func resumedHistoryLiftsPicturesOutOfUserMessages() {
    let history: [JSONValue] = [
      ["role": "user", "text": "What number is shown?\n@image:/Users/me/.hermes/profiles/scout/images/upload_1.png\n[screenshot]", "timestamp": 1],
      ["role": "assistant", "text": "47", "timestamp": 2],
    ]
    let items = TranscriptItem.items(fromHistory: history)
    #expect(items[0].kind == .user)
    #expect(items[0].text == "What number is shown?")
    #expect(items[0].images == ["/Users/me/.hermes/profiles/scout/images/upload_1.png"])
  }

  @Test func storedRowsLiftPicturesToo() {
    let rows: [JSONValue] = [["role": "user", "content": "@image:/tmp/a.jpg\n[screenshot]", "timestamp": 1]]
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.count == 1)
    #expect(items[0].text.isEmpty)
    #expect(items[0].images == ["/tmp/a.jpg"])
  }

  @Test func aPhotoSentFromThePhoneMatchesItsStoredCopy() {
    // The phone shows "Look at this" with a local thumbnail; the Mac stores the words plus the
    // reference. Same signature, so the reconnect merge keeps the bubble instead of redrawing.
    var pending = TranscriptItem(kind: .user, text: "Look at this", timestamp: 1)
    pending.isPending = true
    let stored = TranscriptItem.user("Look at this\n@image:/Users/me/.hermes/images/upload_x.jpg\n[screenshot]", timestamp: 1)
    #expect(pending.signature == stored.signature)
  }

  @Test func listPreviewsSayImageInsteadOfAPath() {
    // The backend's preview is one line, and is cut off at 60 characters with "...".
    #expect(UserContent.preview("@image:/Users/me/.hermes/images/upload_k3m9.jpg [screenshot]") == "Image")
    #expect(UserContent.preview("@image:/a.jpg @image:/b.jpg [screenshot] [screenshot]") == "2 images")
    #expect(UserContent.preview("Can we fix this? @image:/Users/me/.hermes/ima...") == "Can we fix this?")
    #expect(UserContent.preview("Plain words") == "Plain words")
  }
}

/// A message sent into a running reply comes back as a `steer` row: the person's own words.
@Suite struct SentIntoReplyTests {
  @Test func steerRowsAreUserMessagesAndNoticesStaySystem() {
    let history: [JSONValue] = [
      ["role": "user", "text": "Run the slow thing.", "timestamp": 1],
      ["role": "tool", "name": "terminal", "context": "sleep 25", "timestamp": 2],
      ["role": "user", "text": "Change of plan: reply PINEAPPLE.", "display_kind": "steer", "timestamp": 3],
      ["role": "assistant", "text": "PINEAPPLE", "timestamp": 4],
      ["role": "user", "text": "Switched to a new model", "display_kind": "model_switch", "timestamp": 5],
      ["role": "user", "text": "internal nudge", "display_kind": "hidden", "timestamp": 6],
    ]
    let kinds = TranscriptItem.items(fromHistory: history).map(\.kind)
    #expect(kinds == [.user, .tool, .user, .assistant, .system])
  }

  @Test func storedRowsUnwrapTheOutOfBandEnvelope() {
    let wrapped = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output]\nChange of plan: reply PINEAPPLE.\n[/OUT-OF-BAND USER MESSAGE]"
    let items = TranscriptItem.items(fromStoredRows: [["role": "user", "content": .string(wrapped), "timestamp": 1]])
    #expect(items.map(\.text) == ["Change of plan: reply PINEAPPLE."])
  }

  @Test func acceptedCorrectionSplitsTheTurnWhereItArrived() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "Run the slow thing.", timestamp: 0)]
    state.apply(event: "message.start", payload: [:], now: 1)
    state.apply(event: "message.delta", payload: ["text": "Starting it."], now: 2)
    state.apply(event: "tool.start", payload: ["tool_id": "t1", "name": "terminal", "context": "sleep 25"], now: 3)
    state.insertCorrection("Change of plan: reply PINEAPPLE.", now: 4)
    state.apply(event: "tool.complete", payload: ["tool_id": "t1", "name": "terminal"], now: 5)
    state.apply(event: "message.delta", payload: ["text": "PINEAPPLE"], now: 6)
    #expect(state.isStreaming)
    // The call that was running when the message arrived finishes in place, before it.
    #expect(state.items.map(\.kind) == [.user, .assistant, .tool, .user, .assistant])
    #expect(state.items[2].tool?.isDone == true)
    #expect(state.items.last?.text == "PINEAPPLE")
    state.apply(event: "message.complete", payload: ["text": "PINEAPPLE"], now: 7)
    let rows = TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming)
    guard case .answer(let answer) = rows.last else {
      Issue.record("the reply to the correction should be the answer")
      return
    }
    #expect(answer.text == "PINEAPPLE")
  }

  @Test func resumingMidTurnShowsTheCorrectionOnceWithoutRepeatingEarlierSteps() {
    // Recorded: a second client resumed 0.1 s after `session.redirect` answered `redirected`.
    var state = ChatState()
    state.items = TranscriptItem.items(fromHistory: [
      ["role": "user", "text": "Run the slow thing.", "timestamp": 100],
      ["role": "assistant", "text": "Starting it.", "timestamp": 101],
    ])
    let inflight: JSONValue = [
      "assistant": "Starting it.\n\nPINE", "streaming": true, "user": "Run the slow thing.",
      "corrections": ["Change of plan: reply PINEAPPLE."], "correction_offsets": [12],
    ]
    state.applyInflight(inflight, turnStartedAt: 100, now: 103)
    #expect(state.items.map(\.kind) == [.user, .assistant, .user, .assistant])
    #expect(state.items[2].text == "Change of plan: reply PINEAPPLE.")
    #expect(state.items[3].text == "PINE")
    // A second look (a later reconnect) does not add the correction again.
    state.applyInflight(inflight, turnStartedAt: 100, now: 104)
    #expect(state.items.filter { $0.kind == .user }.count == 2)
  }
}

@Suite struct PromptQueueTests {
  @Test func waitsWhileBusyThenGoesOldestFirst() {
    var queue = PromptQueue<Int>()
    let first = queue.enqueue(text: "one", now: 1)
    queue.enqueue(text: "two", attachments: [7], now: 2)
    #expect(queue.next(isBusy: true) == nil)
    #expect(queue.next(isBusy: false)?.id == first.id)
    queue.remove(first.id)
    #expect(queue.next(isBusy: false)?.text == "two")
    #expect(queue.next(isBusy: false)?.attachments == [7])
  }

  @Test func stopPausesUntilResumedAndEmptyingClearsIt() {
    var queue = PromptQueue<Int>()
    queue.pause()
    #expect(!queue.isPaused)  // nothing to pause
    let entry = queue.enqueue(text: "one", now: 1)
    queue.pause()
    #expect(queue.next(isBusy: false) == nil)
    queue.resume()
    #expect(queue.next(isBusy: false)?.id == entry.id)
    queue.pause()
    queue.remove(entry.id)
    #expect(!queue.isPaused)
  }

  @Test func promoteAndRestorePutAnEntryFirst() {
    var queue = PromptQueue<Int>()
    queue.enqueue(text: "one", now: 1)
    let two = queue.enqueue(text: "two", now: 2)
    queue.promote(two.id)
    #expect(queue.entries.map(\.text) == ["two", "one"])
    let taken = queue.remove(two.id)!
    queue.restore(taken)
    #expect(queue.entries.map(\.text) == ["two", "one"])
  }

  @Test func anEntryBeingDeliveredIsNotSentTwice() {
    var queue = PromptQueue<Int>()
    let one = queue.enqueue(text: "one", now: 1)
    queue.enqueue(text: "two", now: 2)
    queue.setDelivering(one.id, true)
    #expect(queue.next(isBusy: false)?.text == "two")
  }

  @Test func entriesHandedToTheMacAreNotSentAgainAndComeBackIfDropped() {
    var queue = PromptQueue<Int>()
    let one = queue.enqueue(text: "one", now: 1)
    queue.moveToMac(one.id)
    #expect(queue.isEmpty)
    #expect(queue.isShowing)
    #expect(queue.next(isBusy: false) == nil)
    let dropped = queue.takeOnMac()
    queue.returnFromMac(dropped)
    #expect(queue.entries.map(\.text) == ["one"])
    #expect(queue.isPaused)
  }

  @Test func takenBackEntriesKeepTheirOwnPlaceInWrittenOrder() {
    var closed = PromptQueue<Int>()
    let command = closed.enqueue(text: "/usage", now: 1)
    let words = closed.enqueue(text: "Implement the fix", attachments: [7], now: 2)
    // A copy of the chat opened since has a message of its own, written later.
    var reopened = PromptQueue<Int>()
    reopened.enqueue(text: "Newer", now: 5)
    // The later entry comes back first (it was left when the chat closed), the failed command after.
    reopened.takeBack([words], paused: false)
    reopened.takeBack([command], paused: false)
    #expect(reopened.entries.map(\.text) == ["/usage", "Implement the fix", "Newer"])
    #expect(reopened.entries[1].attachments == [7])
    #expect(!reopened.isPaused)
    reopened.takeBack([command], paused: true)
    #expect(reopened.entries.map(\.text) == ["/usage", "Implement the fix", "Newer"], "taken back once")
    #expect(reopened.isPaused)
  }
}

/// Messages handed to the Mac's queue while the phone sleeps. Recorded: a second client resumed
/// 0.1 s after `prompt.submit {queued: true}` answered `queued`, while a terminal call ran.
@Suite struct HandedOverTests {
  private let history: [JSONValue] = [
    ["role": "user", "text": "Earlier question", "timestamp": 50],
    ["role": "assistant", "text": "Earlier answer", "timestamp": 60],
    ["role": "user", "text": "Run the slow thing.", "timestamp": 100],
    ["role": "user", "text": "Then reply with only the word PLUM.", "timestamp": 105],
  ]

  @Test func theMacsEarlyCopyLeavesTheRunningTurnUnderItsOwnMessage() {
    let fresh = TranscriptItem.withoutEarlyQueued(
      TranscriptItem.items(fromHistory: history), queued: ["Then reply with only the word PLUM."],
      runningUser: "Run the slow thing.", turnStartedAt: 100)
    #expect(fresh.map(\.text) == ["Earlier question", "Earlier answer", "Run the slow thing."])
    var state = ChatState()
    state.items = fresh
    state.applyInflight(["user": "Run the slow thing.", "assistant": "", "streaming": true], turnStartedAt: 100, now: 106)
    // Without the early copy the running turn's message is recognised, not added a second time.
    #expect(state.items.filter { $0.kind == .user }.map(\.text) == ["Earlier question", "Run the slow thing."])
  }

  @Test func withoutTheRunningMessageTheTurnStartDecides() {
    let fresh = TranscriptItem.withoutEarlyQueued(
      TranscriptItem.items(fromHistory: history), queued: ["Then reply with only the word PLUM."],
      runningUser: nil, turnStartedAt: 100)
    #expect(fresh.count == 3)
    // The same words sent long before stay.
    let older: [JSONValue] = [["role": "user", "text": "Then reply with only the word PLUM.", "timestamp": 10]] + history
    let kept = TranscriptItem.withoutEarlyQueued(
      TranscriptItem.items(fromHistory: older), queued: ["Then reply with only the word PLUM."], runningUser: nil, turnStartedAt: 100)
    #expect(kept.count == 4)
  }

  @Test func theTurnTheMacStartsShowsTheHandedOverWords() {
    var state = ChatState()
    state.items = [TranscriptItem(kind: .user, text: "Run the slow thing.", timestamp: 100)]
    state.apply(event: "message.complete", payload: ["text": "It printed wren-6."], now: 120)
    state.beginHandedOverTurn(texts: ["Then PLUM.", "And KIWI."], now: 121)
    state.apply(event: "message.start", payload: [:], now: 121)
    #expect(state.items.last?.text == "")
    #expect(state.items.filter { $0.kind == .user }.last?.text == "Then PLUM.\n\nAnd KIWI.")
    #expect(state.hasUserMessage("And KIWI."))
    #expect(!state.hasUserMessage("Something else"))
  }
}
