import Foundation

/// `/btw` and `/bg` (alias `/background`): a question answered from a snapshot of the chat, or a
/// task run in a session of its own, beside the reply rather than after it. Neither stops, queues
/// behind or steers a running reply. The gateway answers at once with a task id (`prompt.btw`,
/// `prompt.background`) and the answer arrives later on the chat's own event stream as
/// `btw.complete {task_id, question, text}` or `background.complete {task_id, text}`, `text`
/// starting `error: ` when it failed (`gateway/session_tui_side.py`). The answer is never a row in
/// the stored transcript, so only an app attached when it lands can show it.
public enum SideKind: String, Sendable, Equatable {
  case btw
  case background
}

/// A `/btw` or `/bg` typed into the composer.
public struct SideCommand: Sendable, Equatable {
  public let kind: SideKind
  /// The question or the task, as typed after the name.
  public let text: String
  /// As typed, with its slash (`/bg` or `/background`), for the usage line.
  public let name: String

  /// Nil for any other command.
  public init?(_ invocation: SlashInvocation) {
    switch invocation.name {
    case "btw": kind = .btw
    case "bg", "background": kind = .background
    default: return nil
    }
    text = invocation.arg
    name = "/" + invocation.name
  }

  /// The gateway method that starts it.
  public var method: String { kind == .btw ? "prompt.btw" : "prompt.background" }

  /// What a bare `/btw` or `/bg` shows instead of sending anything (the desktop app's words).
  public var usage: String {
    switch kind {
    case .btw: "Usage: \(name) <question>. It is answered from a snapshot of this conversation without interrupting it."
    case .background: "Usage: \(name) <task>. It runs in a separate session and the result appears here when done."
    }
  }
}

/// One side question or background task: asked (no answer yet), or answered.
public struct SideTask: Sendable, Equatable {
  public let kind: SideKind
  /// The gateway's id (`btw_1a2b3c`); empty until the gateway has said it.
  public var taskID: String
  /// The question or task as sent. `background.complete` does not repeat it, so it comes from the
  /// notice shown when it was sent, when this app sent it.
  public var prompt: String
  /// Nil while it runs; the answer, or `error: ...`, once it lands.
  public var answer: String?

  public init(kind: SideKind, taskID: String, prompt: String, answer: String? = nil) {
    self.kind = kind
    self.taskID = taskID
    self.prompt = prompt
    self.answer = answer
  }

  /// A `btw.complete` or `background.complete` event; nil for any other.
  public init?(event type: String, payload: JSONValue) {
    switch type {
    case "btw.complete": kind = .btw
    case "background.complete": kind = .background
    default: return nil
    }
    taskID = payload["task_id"].scalarText?.trimmingCharacters(in: .whitespaces) ?? ""
    prompt = payload["question"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    answer = payload["text"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The side agent failed: its answer is `error: <what went wrong>`.
  public var isFailed: Bool { answer?.hasPrefix("error:") ?? false }

  /// The answer to show: the error in plain words when it failed.
  public var shownAnswer: String {
    guard let answer else { return "" }
    if isFailed {
      let words = answer.dropFirst("error:".count).trimmingCharacters(in: .whitespacesAndNewlines)
      return words.isEmpty ? "Something went wrong on the Mac." : words
    }
    return answer.isEmpty ? "No answer came back." : answer
  }
}

extension TranscriptItem {
  /// The notice shown as soon as a side question or task is sent. Only on this device.
  public static func sideNotice(_ command: SideCommand, timestamp: Double?) -> TranscriptItem {
    var item = TranscriptItem(kind: .side, text: command.text, timestamp: timestamp)
    item.isLocal = true
    item.side = SideTask(kind: command.kind, taskID: "", prompt: command.text)
    return item
  }

  /// A side question's or background task's answer, as its own card. Only on this device.
  public static func sideAnswer(_ task: SideTask, timestamp: Double?) -> TranscriptItem {
    var item = TranscriptItem(kind: .side, text: task.shownAnswer, timestamp: timestamp)
    item.isLocal = true
    item.side = task
    return item
  }

  /// This is a side answer that has landed (not the notice sent before it).
  public var isSideAnswer: Bool { side?.answer != nil }
}

extension Array where Element == TranscriptItem {
  /// Adds a side answer as its own card, once per task: the same event delivered again (a
  /// reconnect, a second socket) adds nothing and returns nil. A `background.complete` names no
  /// task, so it takes the words from the notice sent with the same task id, when there is one.
  public mutating func addSideAnswer(_ task: SideTask, timestamp: Double?) -> TranscriptItem? {
    var task = task
    if !task.taskID.isEmpty, contains(where: { $0.isSideAnswer && $0.side?.taskID == task.taskID }) { return nil }
    if task.prompt.isEmpty, !task.taskID.isEmpty,
      let asked = last(where: { !$0.isSideAnswer && $0.side?.taskID == task.taskID })?.side?.prompt
    {
      task.prompt = asked
    }
    let item = TranscriptItem.sideAnswer(task, timestamp: timestamp)
    append(item)
    return item
  }

  /// The gateway said which task the notice `noticeID` started. The answer can land before that
  /// does (the gateway starts the side agent before it replies), so an answer already here for
  /// the task takes the notice's words as its heading. Returns the items that changed.
  @discardableResult
  public mutating func noteSideStarted(noticeID: UUID, taskID: String, prompt: String) -> [TranscriptItem] {
    guard !taskID.isEmpty else { return [] }
    var changed: [TranscriptItem] = []
    for index in indices {
      guard self[index].side != nil else { continue }
      if self[index].id == noticeID, self[index].side?.taskID != taskID {
        self[index].side?.taskID = taskID
        changed.append(self[index])
      } else if self[index].isSideAnswer, self[index].side?.taskID == taskID, self[index].side?.prompt.isEmpty == true,
        !prompt.isEmpty
      {
        self[index].side?.prompt = prompt
        changed.append(self[index])
      }
    }
    return changed
  }
}

extension ChatState {
  /// Adds a side answer as its own card, once per task (`[TranscriptItem].addSideAnswer`).
  public mutating func addSideAnswer(_ task: SideTask, now: Double) -> [Effect] {
    guard let item = items.addSideAnswer(task, timestamp: now) else { return [] }
    return [.sideAnswer(item)]
  }

  /// Puts back side notices and answers this device held for the chat (it was left and opened
  /// again, or its history was read afresh), each by its time among the rest. Ones already on
  /// screen take the held copy, which may be newer (the task id or heading arrived meanwhile).
  public mutating func restoreSideItems(_ held: [TranscriptItem]) {
    for item in held {
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        if items[index] != item { items[index] = item }
        continue
      }
      if item.isSideAnswer, let taskID = item.side?.taskID, !taskID.isEmpty,
        items.contains(where: { $0.isSideAnswer && $0.side?.taskID == taskID })
      {
        continue
      }
      let at = item.timestamp.flatMap { time in items.firstIndex { ($0.timestamp ?? 0) > time } } ?? items.endIndex
      items.insert(item, at: at)
    }
  }
}
