import Foundation

/// A stretch of agent activity between a user message and the answer: tool calls,
/// interim notes and reasoning. Shown collapsed as "Worked for 2m".
public struct WorkLog: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var items: [TranscriptItem]
  /// The turn this group belongs to is still running and this is its latest activity.
  public var isLive: Bool
  /// Elapsed seconds when known.
  public var seconds: Double?

  public var toolCount: Int { items.count { $0.kind == .tool } }
  public var hasError: Bool { items.contains { $0.tool?.isError == true } }

  /// "Worked for 2m", "Thought for 8s", "3 tools", or "Working" while the turn runs.
  public var label: String {
    if isLive { return "Working" }
    let tools = toolCount
    if let seconds, seconds >= 1 { return "\(tools > 0 ? "Worked" : "Thought") for \(WorkLog.duration(seconds))" }
    if tools > 0 { return tools == 1 ? "1 tool" : "\(tools) tools" }
    return "Thought"
  }

  static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total)s" }
    if total < 3600 {
      let rest = total % 60
      return rest == 0 || total >= 600 ? "\(total / 60)m" : "\(total / 60)m \(rest)s"
    }
    let minutes = (total % 3600) / 60
    return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
  }
}

/// What the transcript view draws, top to bottom.
public enum TranscriptRow: Identifiable, Sendable, Equatable {
  case user(TranscriptItem)
  /// Assistant text shown in full.
  case answer(TranscriptItem)
  case work(WorkLog)
  /// A question the agent asked (clarify), always visible so it can be answered in place.
  case question(TranscriptItem)
  case system(TranscriptItem)

  public var id: UUID {
    switch self {
    case .user(let item), .answer(let item), .question(let item), .system(let item): return item.id
    case .work(let group): return group.id
    }
  }
}

public enum TranscriptLayout {
  /// Groups raw items into rows.
  ///
  /// Within a turn, the last assistant text is the answer; everything before it (tool calls,
  /// interim notes) folds into a work group. Questions split a group so they stay visible.
  public static func rows(for items: [TranscriptItem], isStreaming: Bool) -> [TranscriptRow] {
    var rows: [TranscriptRow] = []
    var turn: [TranscriptItem] = []
    var turnStart: Double?

    func flush(isLastTurn: Bool) {
      defer { turn = [] }
      guard !turn.isEmpty else { return }
      let live = isLastTurn && isStreaming
      // The answer is the last assistant text, unless activity came after it in a turn that is still running.
      var answerIndex = turn.lastIndex { $0.kind == .assistant && !$0.text.isEmpty }
      if let index = answerIndex, live, index != turn.count - 1 { answerIndex = nil }

      var group: [TranscriptItem] = []
      var emitted: [TranscriptRow] = []
      func closeGroup() {
        guard !group.isEmpty else { return }
        emitted.append(.work(WorkLog(id: group[0].id, items: group, isLive: false, seconds: toolSeconds(group))))
        group = []
      }
      for (index, item) in turn.enumerated() {
        if index == answerIndex {
          closeGroup()
          emitted.append(.answer(item))
          continue
        }
        switch item.kind {
        case .system:
          closeGroup()
          emitted.append(.system(item))
        case .tool where item.tool?.isClarify == true:
          closeGroup()
          emitted.append(.question(item))
        case .assistant where item.text.isEmpty && item.reasoning.isEmpty:
          continue
        default:
          group.append(item)
        }
      }
      closeGroup()

      // The whole turn's wall time belongs on its last work group; a running turn marks it live.
      if let lastWork = emitted.lastIndex(where: { if case .work = $0 { return true } else { return false } }),
        case .work(var work) = emitted[lastWork]
      {
        if live {
          work.isLive = true
        } else if let start = turnStart, let answerIndex, let end = turn[answerIndex].timestamp, end > start {
          work.seconds = end - start
        }
        emitted[lastWork] = .work(work)
      }
      rows.append(contentsOf: emitted)
    }

    for item in items {
      if item.kind == .user {
        flush(isLastTurn: false)
        rows.append(.user(item))
        turnStart = item.timestamp
      } else {
        turn.append(item)
      }
    }
    flush(isLastTurn: true)
    return rows
  }

  private static func toolSeconds(_ items: [TranscriptItem]) -> Double? {
    let durations = items.compactMap { $0.tool?.duration }
    return durations.isEmpty ? nil : durations.reduce(0, +)
  }
}
