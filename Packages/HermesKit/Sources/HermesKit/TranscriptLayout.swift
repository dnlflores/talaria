import Foundation

/// Tool calls and private reasoning between visible assistant messages.
/// Assistant commentary stays in the conversation, never inside this collapsed log.
public struct WorkLog: Identifiable, Sendable, Equatable {
  public let id: UUID
  public var items: [TranscriptItem]
  /// The turn this group belongs to is still running and this is its latest activity.
  public var isLive: Bool
  /// Elapsed seconds when known.
  public var seconds: Double?

  public var toolCount: Int { items.count { $0.kind == .tool } }
  public var hasError: Bool { items.contains { $0.tool?.isError == true } }

  /// An expanded log reveals calls in chronological batches; reasoning is not a tool call.
  public func page(toolLimit: Int) -> [TranscriptItem] {
    var calls = 0
    return Array(items.prefix { item in
      if item.kind == .tool {
        guard calls < max(0, toolLimit) else { return false }
        calls += 1
      }
      return true
    })
  }

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

  /// Every file across a chat's turns, once each, in the order first seen. A file several turns
  /// edited keeps all their diffs, so its counts cover the whole chat.
  public static func combined(_ turns: [TurnFiles]) -> [FileReference] {
    var index: [String: Int] = [:]
    var out: [FileReference] = []
    for turn in turns {
      for file in turn.files {
        if let at = index[file.path] {
          out[at].diffs.append(contentsOf: file.diffs)
        } else {
          index[file.path] = out.count
          out.append(file)
        }
      }
    }
    return out
  }
}

/// What the transcript view draws, top to bottom.
public enum TranscriptRow: Identifiable, Sendable, Equatable {
  case user(TranscriptItem)
  /// Assistant text shown in full.
  case answer(TranscriptItem)
  /// An update from the agent, including text still being written. Not private reasoning.
  case commentary(TranscriptItem)
  case work(WorkLog)
  /// A question the agent asked (clarify), always visible so it can be answered in place.
  case question(TranscriptItem)
  /// A finished file edit with its diff, shown as its own message (opened by default) rather
  /// than folded into the work log, like the desktop app's edit cards.
  case edit(TranscriptItem)
  case system(TranscriptItem)
  /// A `/btw` or `/bg` sent from here (`side.answer` nil), or its answer as its own card.
  case side(TranscriptItem)
  case files(TurnFiles)

  public var id: UUID {
    switch self {
    case .user(let item), .answer(let item), .commentary(let item), .question(let item), .edit(let item),
      .system(let item), .side(let item):
      return item.id
    case .work(let group): return group.id
    case .files(let files): return files.id
    }
  }
}

public enum TranscriptLayout {
  /// Groups raw items into rows.
  ///
  /// Every assistant message stays visible in order. Only tools and actual reasoning fold
  /// into work groups. While running, text uses commentary styling so it never flashes as
  /// a final answer before the backend identifies the next tool call.
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
      // Side questions and tasks asked during a turn show after all of it, as the desktop app
      // shows them after the reply they were asked beside: a reply still running grows above
      // them instead of pushing them up between its steps.
      let sides = turn.filter { $0.kind == .side }
      turn.removeAll { $0.kind == .side }
      defer {
        rows.append(contentsOf: sides.map(TranscriptRow.side))
        turn = []
      }
      guard !turn.isEmpty else { return }
      let live = isLastTurn && isStreaming
      let answerIndex = live ? nil : turn.lastIndex { $0.kind == .assistant && !$0.isCommentary && !$0.text.isEmpty }

      var group: [TranscriptItem] = []
      var emitted: [TranscriptRow] = []
      func closeGroup() {
        guard !group.isEmpty else { return }
        emitted.append(.work(WorkLog(id: group[0].id, items: group, isLive: false, seconds: toolSeconds(group))))
        group = []
      }
      for (index, item) in turn.enumerated() {
        switch item.kind {
        case .system:
          closeGroup()
          emitted.append(.system(item))
        case .side:
          // Taken out above; never reached.
          break
        case .tool where item.tool?.isClarify == true:
          closeGroup()
          emitted.append(.question(item))
        case .tool where item.tool.map(EditSummary.isShown) == true:
          // The point of the turn: what changed stays on screen, in order, between the logs of
          // the reads and commands around it.
          closeGroup()
          emitted.append(.edit(item))
        case .assistant:
          if !item.reasoning.isEmpty {
            // A second, stable identity keeps reasoning and words from sharing a row id.
            var thought = TranscriptItem(id: item.id.derived(salt: 0x52), kind: .assistant, timestamp: item.timestamp)
            thought.reasoning = item.reasoning
            thought.isStreaming = item.isStreaming
            group.append(thought)
          }
          if !item.text.isEmpty {
            closeGroup()
            emitted.append(index == answerIndex ? .answer(item) : .commentary(item))
          }
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
