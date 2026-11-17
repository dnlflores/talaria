import Foundation

/// Edit (the transcript's long-press menu on the newest message): the message's words go into the
/// composer to be changed, and sending them takes that turn off the Mac's copy as Try again does
/// (`RetryTurn`, `session.mutate` `rewind`) and sends the new words as the turn in its place. The
/// desktop app's edit of the newest turn (`use-prompt-actions/rewind.ts`, `planEdit`) does the
/// same and asks for no confirmation; editing an older turn is left to the desktop.
public enum EditTurn {
  /// The words the composer shows to edit. Nil when the phone cannot send the message again as
  /// edited words: it carries pictures or files, it ran a skill or command (`/work ...`), or it
  /// holds no words.
  public static func words(of item: TranscriptItem) -> String? {
    guard item.kind == .user, item.images.isEmpty, item.attachments.isEmpty else { return nil }
    let text = item.text
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    // A skill turn reads back as its invocation; sent as words it would not run the skill.
    if SlashInvocation(text) != nil { return nil }
    // Files picked on the phone go out as `@file:` references beside the words.
    let tokens = text.split(whereSeparator: \.isWhitespace)
    if tokens.contains(where: { $0.hasPrefix("@file:") }) { return nil }
    return text
  }

  /// Where the transcript offers Edit: the person's newest message, among the messages Try again
  /// is offered on (`RetryTurn.offeredItems`), when its words can be edited. Never the reply.
  public static func offeredItems(in items: [TranscriptItem]) -> Set<UUID> {
    let offers = RetryTurn.offeredItems(in: items)
    return Set(items.filter { offers.contains($0.id) && words(of: $0) != nil }.map(\.id))
  }

  /// Whether the message being edited is still the turn the Mac would go back to: the newest
  /// message from the person on screen is that message (`itemID`), and it is the stored row
  /// `rowID` the Mac named. Otherwise the chat has moved on and nothing may be taken back.
  public static func isTarget(_ items: [TranscriptItem], itemID: UUID, rowID: Int) -> Bool {
    guard let shown = RetryTurn.shownTurn(items), shown.id == itemID else { return false }
    return shown.rowID == rowID
  }

  /// Whether a rewind's receipt took back the message being edited (stored as `rowID`), so the
  /// edited words may go out in its place. A receipt replayed from an earlier Try again may name
  /// another turn, and one for an unknown row never matches.
  public static func matches(_ receipt: RewindReceipt, rowID: Int?) -> Bool {
    guard let rowID, receipt.didRewind else { return false }
    return receipt.targetID == rowID
  }

  /// What goes out once a rewind is claimed (`resend(claimed:retryText:caller:callerEditsTarget:)`).
  public struct Resend: Equatable, Sendable {
    /// The words sent as the new turn; nil when there are none.
    public let words: String?
    /// Whether `words` are an edit's, not the words the Mac took back.
    public let isEdit: Bool
    /// The caller's edit, when this rewind does not send it: it stays in the composer.
    public let kept: String?
  }

  /// What goes out after the copy of a chat claims a rewind's one resend. The rewind may be one
  /// another copy sent and is replayed here after its answer was lost (`claimed` is its edit's
  /// words, nil for Try again), and the caller may be an edit (`caller`) or Try again (nil).
  /// An edit always beats Try again: a Try again never sends the words the Mac took back in
  /// place of an edit, and an edit of the message the rewind took back (`callerEditsTarget`)
  /// sends its words. Between two edits of that message the caller's, the newer, go. An edit
  /// of another message is not sent and is kept for the composer.
  public static func resend(claimed: String?, retryText: String?, caller: String?, callerEditsTarget: Bool) -> Resend {
    if let caller, callerEditsTarget { return Resend(words: caller, isEdit: true, kept: nil) }
    if let claimed { return Resend(words: claimed, isEdit: true, kept: caller == claimed ? nil : caller) }
    return Resend(words: retryText, isEdit: false, kept: caller)
  }

  /// What the composer holds when an edit could not replace the message: the edited words, then
  /// the draft that was set aside for the edit, so neither is lost.
  public static func keeping(edited: String, stash: String) -> String {
    let edited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
    let stash = stash.trimmingCharacters(in: .whitespacesAndNewlines)
    if stash.isEmpty { return edited }
    if edited.isEmpty || edited == stash { return stash }
    return edited + "\n\n" + stash
  }
}
