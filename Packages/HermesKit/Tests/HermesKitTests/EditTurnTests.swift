import Foundation
import Testing

@testable import HermesKit

/// Edit: which message offers it, which words go into the composer, when the edit may still
/// replace the turn, and what the composer keeps when it cannot.
struct EditTurnTests {
  private func stored(_ text: String, row: Int?) -> TranscriptItem {
    var item = TranscriptItem.user(text, timestamp: 1)
    item.rowID = row
    return item
  }

  // MARK: The words to edit

  @Test func plainWordsAreEdited() {
    #expect(EditTurn.words(of: stored("Fix the typo in teh README", row: 3)) == "Fix the typo in teh README")
    #expect(EditTurn.words(of: stored("Line one\n\nLine two", row: 3)) == "Line one\n\nLine two")
  }

  @Test func picturesFilesAndCommandsAreNotEdited() {
    // A picture stored beside the words.
    #expect(EditTurn.words(of: .user("What is this?\n@image:/tmp/photo.jpg", timestamp: 1)) == nil)
    // A picture picked on this phone, still shown from its local copy.
    var picked = TranscriptItem.outgoing("Look", shown: nil, timestamp: 1)
    picked.attachments = [AttachmentChip(kind: .image, name: "photo-1.jpg")]
    #expect(EditTurn.words(of: picked) == nil)
    // A file sent as a reference.
    #expect(EditTurn.words(of: stored("Read this\n\n@file:`/tmp/notes.md`", row: 3)) == nil)
    // A skill turn reads back as its invocation.
    #expect(EditTurn.words(of: stored("/work fix the leak", row: 3)) == nil)
    // No words.
    #expect(EditTurn.words(of: stored("   ", row: 3)) == nil)
    // Not the person's message.
    #expect(EditTurn.words(of: TranscriptItem(kind: .assistant, text: "Reply")) == nil)
  }

  @Test func aPathIsWordsNotACommand() {
    #expect(EditTurn.words(of: stored("/Users/me/notes.md is empty", row: 3)) == "/Users/me/notes.md is empty")
  }

  // MARK: Where it is offered

  @Test func onlyTheNewestMessageOffersEdit() {
    let first = stored("One", row: 1)
    let firstReply = TranscriptItem(kind: .assistant, text: "Reply one")
    let second = stored("Two", row: 3)
    let reply = TranscriptItem(kind: .assistant, text: "Reply two")
    #expect(EditTurn.offeredItems(in: [first, firstReply, second, reply]) == [second.id], "the message, never the reply")
    #expect(EditTurn.offeredItems(in: [first, firstReply]) == [first.id])

    var pending = TranscriptItem.outgoing("Three", shown: nil, timestamp: 4)
    #expect(EditTurn.offeredItems(in: [first, firstReply, pending]).isEmpty, "a message on its way")
    pending.isPending = false
    pending.isFailed = true
    #expect(EditTurn.offeredItems(in: [first, firstReply, pending]).isEmpty, "a message that failed to go")

    let picture = TranscriptItem.user("@image:/tmp/a.jpg\n[screenshot]", timestamp: 5)
    #expect(EditTurn.offeredItems(in: [first, firstReply, picture]).isEmpty, "a message with a picture")
    #expect(EditTurn.offeredItems(in: []).isEmpty)
  }

  // MARK: Still the turn to replace

  @Test func theEditedMessageMustStillBeTheMacsNewestTurn() {
    let earlier = stored("Earlier", row: 3)
    let edited = stored("Check the build", row: 5)
    let items = [earlier, TranscriptItem(kind: .assistant, text: "Answer"), edited]
    #expect(EditTurn.isTarget(items, itemID: edited.id, rowID: 5))
    // The Mac's newest message is another row, even with the same words.
    #expect(!EditTurn.isTarget(items, itemID: edited.id, rowID: 7))
    // A newer message shows under the one being edited.
    let newer = stored("Something else", row: 7)
    #expect(!EditTurn.isTarget(items + [newer], itemID: edited.id, rowID: 7))
    // The screen does not know the edited message's row.
    let unnamed = TranscriptItem.user("Check the build", timestamp: 2)
    #expect(!EditTurn.isTarget([earlier, unnamed], itemID: unnamed.id, rowID: 5))
    #expect(!EditTurn.isTarget([], itemID: edited.id, rowID: 5))
  }

  @Test func onlyAReceiptForTheEditedRowLetsTheEditGo() throws {
    let receipt = RewindReceipt(try JSONValue.parse("""
      {"status": "applied", "rewound_count": 2, "target_message": {"id": 12, "content": "Old words"}, "new_head_id": 11}
      """))
    #expect(EditTurn.matches(receipt, rowID: 12))
    #expect(!EditTurn.matches(receipt, rowID: 14), "an earlier Try again took back another turn")
    #expect(!EditTurn.matches(receipt, rowID: nil), "a row the screen never knew")
    let nothing = RewindReceipt(try JSONValue.parse(#"{"status": "nothing", "rewound_count": 0}"#))
    #expect(!EditTurn.matches(nothing, rowID: 12), "nothing came off")
  }

  // MARK: Keeping the words

  @Test func neitherTheEditNorTheDraftIsLost() {
    #expect(EditTurn.keeping(edited: "New words", stash: "") == "New words")
    #expect(EditTurn.keeping(edited: "", stash: "Half a thought") == "Half a thought")
    #expect(EditTurn.keeping(edited: "New words", stash: "Half a thought") == "New words\n\nHalf a thought")
    #expect(EditTurn.keeping(edited: " Same ", stash: "Same") == "Same")
  }
}
