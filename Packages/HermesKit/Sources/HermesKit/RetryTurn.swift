import Foundation

/// Try again (`/retry`, or the transcript's long-press menu): the newest message from the person
/// and everything after it come off the Mac's copy (`session.mutate` `rewind`), then the same
/// words go out again as a new turn. Mirrors the desktop app's `/retry`
/// (`use-prompt-actions/slash-session-commands.ts`: `userTurnFromEnd`, `retryText`).
public enum RetryTurn {
  /// What the chat's snapshot offers to try again.
  public enum Pick: Sendable, Equatable {
    /// No message from the person to go back to.
    case nothing
    /// The newest message carries pictures or parts that cannot be sent again as they were.
    case unsupported
    /// The stored row to rewind to (`row_id`) and the words to send again.
    case target(rowID: Int, text: String)
  }

  /// Rows Hermes writes around a compression; never a message to go back to.
  static let compactionMarkers = ["[CONTEXT COMPACTION", "[CONTEXT SUMMARY]:", "[END OF PRIOR CONTEXT"]
  static let textParts: Set<String> = ["input_text", "output_text", "text"]

  /// A message the person wrote, as `session.resume` lists the chat's rows: a user row with no
  /// display kind other than a typed `/steer`, a durable `row_id`, still live (a row a compression
  /// archived is only shown), and not a compaction handoff. Notices Hermes stores as user rows
  /// (a finished background process, a model switch) carry a display kind, so they never count.
  public static func isUserTurn(_ row: JSONValue) -> Bool {
    guard row["role"].string == "user" else { return false }
    let kind = row["display_kind"].stringValue
    guard kind.isEmpty || kind == "steer" else { return false }
    guard case .number(let id) = row["row_id"], id == id.rounded(), abs(id) < 9e15 else { return false }
    guard !row["archived"].truthy else { return false }
    if let text = row["content"].string, compactionMarkers.contains(where: text.contains) { return false }
    return true
  }

  /// The newest message the person wrote among the snapshot's rows.
  public static func newestUserTurn(in rows: [JSONValue]) -> JSONValue? {
    rows.last(where: isUserTurn)
  }

  /// The words to send again, read losslessly (the gateway's `retryable_user_text`): text parts
  /// only. `nil` when the message carries anything else (a picture, an annotated part, an
  /// `@image:` line), since that cannot be sent again as it was; `""` when it holds no words.
  public static func text(_ content: JSONValue) -> String? {
    let parts: [JSONValue]
    if content.string != nil {
      parts = [content]
    } else if let array = content.array {
      parts = array
    } else {
      return nil
    }
    var text = ""
    for part in parts {
      if let words = part.string {
        text += words
      } else if let fields = part.object, fields.count == 2, textParts.contains(part["type"].stringValue),
        let words = part["text"].string
      {
        text += words
      } else {
        return nil
      }
    }
    // A picture is stored as an `@image:` line beside the words; sending the line back is not
    // sending the picture.
    if !UserContent(text).images.isEmpty { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
  }

  /// What the snapshot's rows offer to try again.
  public static func pick(from rows: [JSONValue]) -> Pick {
    guard let row = newestUserTurn(in: rows), let id = row["row_id"].int else { return .nothing }
    guard let words = text(row["content"]) else { return .unsupported }
    return words.isEmpty ? .nothing : .target(rowID: id, text: words)
  }

  /// The newest message from the person on screen and the reply under it: where the transcript
  /// offers Try again. Nothing while a message is still on its way or failed to go.
  public static func offeredItems(in items: [TranscriptItem]) -> Set<UUID> {
    guard let userIndex = items.lastIndex(where: { $0.kind == .user && !$0.isLocal }) else { return [] }
    let user = items[userIndex]
    guard !user.isPending, !user.isFailed else { return [] }
    var ids: Set<UUID> = [user.id]
    if let reply = items[(userIndex + 1)...].last(where: { $0.kind == .assistant && !$0.isStreaming && !$0.text.isEmpty }) {
      ids.insert(reply.id)
    }
    return ids
  }

  /// Whether the newest message from the person on screen is the one the Mac would go back to.
  /// When they differ, the Mac's copy moved on (another device sent something) and nothing may be
  /// rewound from this view.
  public static func showsSameTurn(_ items: [TranscriptItem], as row: JSONValue) -> Bool {
    guard let shown = items.last(where: { $0.kind == .user && !$0.isLocal && !$0.isFailed }) else { return false }
    guard let stored = TranscriptItem.items(fromStoredRows: [row]).last(where: { $0.kind == .user }) else { return false }
    return shown.signature == stored.signature
  }

  /// The transcript without the turn that was taken back: the newest message from the person
  /// and everything after it, when that message reads as `text`. Otherwise unchanged (the
  /// reload that follows shows the Mac's copy either way).
  public static func cut(_ items: [TranscriptItem], text: String) -> [TranscriptItem] {
    guard let index = items.lastIndex(where: { $0.kind == .user && !$0.isLocal && !$0.isFailed }) else { return items }
    let resent = TranscriptItem.user(TranscriptItem.storedText(submitted: text), timestamp: nil)
    guard items[index].signature == resent.signature else { return items }
    return Array(items[..<index])
  }

  /// What the person's bubble shows for words sent again: a skill turn as its invocation, never
  /// the expanded skill; nil when that is the words themselves.
  public static func display(for text: String) -> String? {
    let shown = TranscriptItem.storedText(submitted: text)
    return shown == text ? nil : shown
  }
}

/// A rewind sent to the Mac, kept until its answer is known. A repeat after a lost answer sends
/// this exact request again (same id, same fences): the Mac answers an exact retry with the
/// receipt it already wrote, so a rewind is never applied twice, and a newer turn is never taken
/// back by a target derived from a transcript the first attempt already shortened.
public struct RewindRequest: Sendable, Equatable {
  public let requestID: String
  public let targetRowID: Int
  public let fences: SessionFences

  public init(requestID: String = UUID().uuidString.lowercased(), targetRowID: Int, fences: SessionFences) {
    self.requestID = requestID
    self.targetRowID = targetRowID
    self.fences = fences
  }
}

/// The Mac's answer to a rewind: how many rows came off, and the message it went back to.
public struct RewindReceipt: Sendable, Equatable {
  /// `nothing` when nothing was cut.
  public let status: String
  public let rewoundCount: Int
  /// `target_message.id`: the stored row of the message taken back.
  public let targetID: Int?
  public let targetContent: JSONValue
  public let targetTimestamp: Double?

  public init(_ json: JSONValue) {
    // The receipt's fields, at the top or under `result`.
    let body = json["rewound_count"].isNull && json["target_message"].isNull && !json["result"].isNull ? json["result"] : json
    status = body["status"].string ?? json["status"].stringValue
    rewoundCount = body["rewound_count"].int ?? 0
    let target = body["target_message"]
    targetID = target["id"].int
    targetContent = target["content"]
    targetTimestamp = TranscriptItem.seconds(target["timestamp"])
  }

  /// Rows came off the Mac's copy.
  public var didRewind: Bool { status != "nothing" && rewoundCount > 0 }

  /// The words to send again (`RetryTurn.text`).
  public var retryText: String? { RetryTurn.text(targetContent) }
}
