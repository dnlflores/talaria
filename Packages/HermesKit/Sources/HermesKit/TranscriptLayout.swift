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

  /// "Worked for 2m", "Thought for 8s", "3 tools", or the count so far while the turn runs
  /// (the transcript's working row says what is happening now).
  public var label: String {
    let tools = toolCount
    if isLive { return tools == 0 ? "Working" : tools == 1 ? "1 tool so far" : "\(tools) tools so far" }
    if let seconds, seconds >= 1 { return "\(tools > 0 ? "Worked" : "Thought") for \(WorkLog.duration(seconds))" }
    if tools > 0 { return tools == 1 ? "1 tool" : "\(tools) tools" }
    return "Thought"
  }

  public static func duration(_ seconds: Double) -> String {
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

/// The files one finished turn wrote, edited or delivered, shown under its answer.
public struct TurnFiles: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var files: [FileReference]
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
  case files(TurnFiles)

  public var id: UUID {
    switch self {
    case .user(let item), .answer(let item), .question(let item), .system(let item): return item.id
    case .work(let group): return group.id
    case .files(let files): return files.id
    }
  }
}

public enum TranscriptLayout {
  /// Groups raw items into rows.
  ///
  /// Within a finished turn, the last assistant text is the answer; everything before it (tool
  /// calls, interim notes) folds into a work group. Questions split a group so they stay visible.
  ///
  /// A running turn has no answer yet: text the model is writing may be a note before its next
  /// tool call, and the backend says so only once that call is under way. Shown as the answer it
  /// would jump into the steps a moment later, so all of it stays in the steps until the turn
  /// ends, and the last text becomes the answer then.
  public static func rows(for items: [TranscriptItem], isStreaming: Bool) -> [TranscriptRow] {
    var cache: [String: [FileReference]] = [:]
    return rows(for: items, isStreaming: isStreaming, fileCache: &cache)
  }

  /// Same, reusing the files found in finished turns last time. The layout runs on every streamed
  /// token, and a finished turn's files do not change, so they are looked up once.
  public static func rows(
    for items: [TranscriptItem], isStreaming: Bool, fileCache cache: inout [String: [FileReference]]
  ) -> [TranscriptRow] {
    var rows: [TranscriptRow] = []
    var usedKeys = Set<String>()
    var turn: [TranscriptItem] = []
    var turnStart: Double?

    func flush(isLastTurn: Bool) {
      defer { turn = [] }
      guard !turn.isEmpty else { return }
      let live = isLastTurn && isStreaming
      let answerIndex = live ? nil : turn.lastIndex { $0.kind == .assistant && !$0.text.isEmpty }

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

      // A finished turn lists what it made, so the files are one tap from the answer that mentions them.
      if !live, let anchor = turn.last {
        let key = "\(turn[0].id)|\(anchor.id)|\(turn.count)|\(turn.count { $0.tool?.isDone == true })"
        let files = cache[key] ?? FileExtraction.files(in: turn)
        cache[key] = files
        usedKeys.insert(key)
        if !files.isEmpty { rows.append(.files(TurnFiles(id: anchor.id.derived(salt: 0x46), files: files))) }
      }
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
    if cache.count > usedKeys.count { cache = cache.filter { usedKeys.contains($0.key) } }
    return rows
  }

  private static func toolSeconds(_ items: [TranscriptItem]) -> Double? {
    let durations = items.compactMap { $0.tool?.duration }
    return durations.isEmpty ? nil : durations.reduce(0, +)
  }
}

extension UUID {
  /// A second identity that stays fixed for a given UUID, for rows that hang off an item.
  func derived(salt: UInt8) -> UUID {
    var bytes = uuid
    bytes.0 ^= salt
    bytes.15 ^= salt
    return UUID(uuid: bytes)
  }
}
