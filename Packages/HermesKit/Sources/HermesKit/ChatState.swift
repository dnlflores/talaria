import Foundation

/// The open conversation: its transcript and live status, advanced by gateway events.
///
/// This is a value type with no I/O so the event handling can be tested against recorded
/// sequences. The rules mirror the hermesdash web client, which is the reference
/// implementation this app was ported from.
public struct ChatState: Sendable, Equatable {
  public var items: [TranscriptItem] = []
  /// A turn is running on the Mac: the model is thinking, a tool is running, or the answer is streaming.
  public var isStreaming = false {
    didSet {
      if !isStreaming {
        turnStartedAt = nil
        preparingTool = nil
      }
    }
  }
  /// The model is writing the arguments of a call to this tool (a file's contents, a command).
  /// The call has not started, but the text before it is settled as a step.
  public var preparingTool: String?
  /// The short "what it is doing" line the backend sends between tokens.
  public var status = ""
  public var info = SessionInfo()
  public var title = ""
  /// When the running turn started (seconds since 1970), for the elapsed time on screen.
  public var turnStartedAt: Double?

  public init() {}

  /// What the running turn is doing right now, or `nil` when no turn runs.
  public var activity: TurnActivity? {
    guard isStreaming else { return nil }
    if items.contains(where: { $0.tool?.pendingRequest != nil }) { return .waiting }
    if let name = preparingTool { return .running(ToolCall(callID: "preparing", name: name)) }
    guard let last = items.last else { return .thinking }
    if let tool = last.tool, !tool.isDone { return .running(tool) }
    if last.kind == .assistant, last.isStreaming, !last.text.isEmpty { return .writing }
    return .thinking
  }

  /// Marks a turn as running from `now`, keeping an earlier start when one is known.
  public mutating func beginTurn(now: Double) {
    isStreaming = true
    if turnStartedAt == nil { turnStartedAt = now }
  }

  /// Applies what `session.resume` says about a turn that is already running. The inflight
  /// snapshot only covers streamed text, so a turn that is running a tool can arrive with no
  /// inflight at all; `running` is the authority.
  public mutating func applyLiveStatus(isRunning: Bool, startedAt: Double?, now: Double) {
    guard isRunning else { return }
    beginTurn(now: now)
    if let startedAt, startedAt > 0, startedAt <= now + 5 { turnStartedAt = startedAt }
  }

  /// Things the caller should do in response to an event.
  public enum Effect: Sendable, Equatable {
    case notice(String)
    case failure(String)
    /// Another Hermes process holds this chat, so the turn never ran. `text` is what the user
    /// had typed, taken back out of the transcript so it can return to the composer.
    case refused(message: String, text: String)
    case sessionsChanged
    case requestCancelled(String)
    case turnFinished
  }

  // MARK: Stream helpers

  private var streamIndex: Int? {
    guard let last = items.indices.last, items[last].kind == .assistant, items[last].isStreaming else { return nil }
    return last
  }

  private mutating func ensureStream(now: Double) -> Int {
    if let index = streamIndex { return index }
    var item = TranscriptItem(kind: .assistant, timestamp: now)
    item.isStreaming = true
    items.append(item)
    return items.count - 1
  }

  // MARK: Loading

  /// Adds the turn that was already running when the session was resumed.
  ///
  /// The backend stores the user's message when the turn starts, so it is usually in the
  /// transcript already: it is added only when the last user message differs or was
  /// already answered (the same words sent again).
  /// - Parameter turnStartedAt: when the running turn began, from `session.resume`. It tells the
  ///   turn's own message, which the backend stores as the turn starts, from an earlier message
  ///   with the same words.
  public mutating func applyInflight(_ inflight: JSONValue, turnStartedAt: Double? = nil, now: Double) {
    guard !inflight.isNull else { return }
    let streaming = inflight["streaming"].truthy
    if let user = inflight["user"].string, !user.isEmpty, inflight["display_kind"].stringValue.isEmpty {
      let incoming = TranscriptItem(kind: .user, text: user, timestamp: now)
      let known = items.lastIndex { $0.kind == .user }.map { index in
        items[index].signature == incoming.signature && isCurrentTurnMessage(at: index, turnStartedAt: turnStartedAt)
      } ?? false
      if !known { items.append(incoming) }
    }
    // `assistant` is everything the turn has streamed, the steps already settled included; the
    // history holds those steps as their own messages, so only what follows them is still open.
    let turnStart = items.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? 0
    let settled = items[turnStart...].filter { $0.kind == .assistant }.map(\.text)
    let partial = ChatState.unsettledText(inflight["assistant"].stringValue, settled: settled)
    if !partial.isEmpty || streaming {
      var item = TranscriptItem(kind: .assistant, text: partial, timestamp: now)
      item.isStreaming = streaming
      items.append(item)
    }
    if streaming { beginTurn(now: now) } else { isStreaming = false }
  }

  /// The end of a turn's streamed text that is not one of its settled steps.
  static func unsettledText(_ streamed: String, settled: [String]) -> String {
    var rest = Substring(streamed)
    for text in settled {
      let step = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !step.isEmpty else { continue }
      let trimmed = rest.drop { $0.isWhitespace }
      if trimmed.hasPrefix(step) {
        rest = trimmed.dropFirst(step.count)
      } else if let range = rest.range(of: step) {
        rest = rest[range.upperBound...]
      }
    }
    return String(rest.drop { $0.isWhitespace })
  }

  /// Adds the calls a running turn has started that the resumed history leaves out:
  /// `session.resume` lists a call only once its result is stored, while the stored rows name it
  /// as soon as it starts. Returns whether anything was added.
  public mutating func addRunningTools(fromStoredRows rows: [JSONValue], now: Double) -> Bool {
    guard isStreaming else { return false }
    let stored = TranscriptItem.items(fromStoredRows: rows)
    let turn = stored.lastIndex { $0.kind == .user }.map { stored[($0 + 1)...] } ?? stored[...]
    let known = Set(items.compactMap { $0.tool?.callID })
    // Questions arrive as requests and attach to their own row.
    let running = turn.filter { item in
      guard let tool = item.tool else { return false }
      return !tool.isDone && !tool.isClarify && !known.contains(tool.callID)
    }
    guard !running.isEmpty else { return false }
    settleStream()
    preparingTool = nil
    items.append(contentsOf: running)
    return true
  }

  /// Ends the text being streamed: a step that is done, or nothing if it never got text.
  private mutating func settleStream() {
    guard let index = streamIndex else { return }
    if items[index].text.isEmpty, items[index].reasoning.isEmpty {
      items.remove(at: index)
    } else {
      items[index].isStreaming = false
    }
  }

  /// Whether the user message at `index` is the one the running turn answers.
  private func isCurrentTurnMessage(at index: Int, turnStartedAt: Double?) -> Bool {
    if let start = turnStartedAt, let sent = items[index].timestamp { return sent >= start - 5 }
    // No start time: a plain finished reply after it means that message was answered and the
    // turn is a new one. Commentary between tool calls is followed by tool rows, so a turn
    // that has used tools is still the same turn.
    let after = items[(index + 1)...]
    guard let last = after.last else { return true }
    let answered = last.kind == .assistant && !last.text.isEmpty && !last.isStreaming
    return !answered || after.contains { $0.kind == .tool }
  }

  // MARK: Events

  @discardableResult
  public mutating func apply(event type: String, payload: JSONValue, now: Double) -> [Effect] {
    switch type {
    case "message.start":
      _ = ensureStream(now: now)
      beginTurn(now: now)
      status = ""

    case "message.delta":
      let index = ensureStream(now: now)
      items[index].text += payload["text"].stringValue
      preparingTool = nil
      beginTurn(now: now)
      status = ""

    case "reasoning.delta":
      let index = ensureStream(now: now)
      items[index].reasoning += payload["text"].stringValue
      beginTurn(now: now)

    case "thinking.delta":
      status = payload["text"].stringValue
      if !status.isEmpty { beginTurn(now: now) }

    case "tool.generating":
      // The model has moved on to writing a tool call, so the text before it is a step, not the
      // answer. Its `message.interim` comes later, sometimes much later for a large file.
      settleStream()
      preparingTool = ToolCall.displayName(payload["name"].stringValue)
      beginTurn(now: now)

    case "tool.progress":
      beginTurn(now: now)

    case "message.interim":
      // Seals the text before a tool call. It was usually streamed already, and may have been
      // settled by `tool.generating`; the interim text replaces it rather than repeating it.
      let text = payload["text"].stringValue
      if let index = items.indices.last, items[index].kind == .assistant,
        items[index].isStreaming || items[index].text == text || payload["already_streamed"].truthy
      {
        if !text.isEmpty { items[index].text = text }
        items[index].isStreaming = false
      } else if !text.isEmpty {
        items.append(TranscriptItem(kind: .assistant, text: text, timestamp: now))
      }
      beginTurn(now: now)

    case "tool.start":
      settleStream()
      preparingTool = nil
      let call = ToolCall(
        callID: payload["tool_id"].scalarText ?? UUID().uuidString, name: payload["name"].string ?? "tool",
        context: payload["context"].stringValue, args: payload["args"])
      items.append(.tool(call, timestamp: now))
      status = ""
      beginTurn(now: now)

    case "tool.complete":
      let callID = payload["tool_id"].scalarText ?? ""
      var index = items.lastIndex { $0.tool?.callID == callID }
      if index == nil {
        let call = ToolCall(
          callID: callID.isEmpty ? UUID().uuidString : callID, name: payload["name"].string ?? "tool",
          context: payload["summary"].stringValue, args: payload["args"])
        items.append(.tool(call, timestamp: now))
        index = items.count - 1
      }
      guard let index, var call = items[index].tool else { break }
      let summary = payload["summary"].stringValue
      call.isDone = true
      call.summary = summary
      call.duration = payload["duration_s"].double
      call.result = payload["result"].scalarText ?? (payload["result"].isNull ? "" : payload["result"].text())
      call.isError = summary.contains(/(?i)error/) && !summary.contains(/(?i)no error/)
      if call.args.isNull, !payload["args"].isNull { call.args = payload["args"] }
      if let diff = payload["inline_diff"].string, !diff.isEmpty { call.inlineDiff = diff }
      if call.isClarify {
        call.pendingRequest = nil
        call.answers = ClarifyAnswer.parse(call.result, questionCount: call.questions.count) ?? call.answers
      }
      items[index].tool = call

    case "message.complete":
      let text = payload["text"].stringValue
      if let index = streamIndex {
        if !text.isEmpty { items[index].text = text }
        items[index].isStreaming = false
        items[index].timestamp = now
      } else if !text.isEmpty, !(items.last?.kind == .assistant && items.last?.text == text) {
        items.append(TranscriptItem(kind: .assistant, text: text, timestamp: now))
      }
      isStreaming = false
      status = ""
      if let model = payload["usage"]["model"].string, !model.isEmpty { info.model = model }
      return [.sessionsChanged, .turnFinished]

    case "session.info":
      info.merge(payload)

    case "session.title":
      if let value = payload["title"].string, !value.isEmpty { title = value }

    case "request.cancel":
      guard let requestID = payload["id"].scalarText else { break }
      if let index = items.firstIndex(where: { $0.tool?.pendingRequest?.id == requestID }) {
        items[index].tool?.pendingRequest = nil
        items[index].tool?.isCancelled = true
      }
      return [.requestCancelled(requestID)]

    default:
      return applyOther(type, payload: payload)
    }
    return []
  }

  private mutating func applyOther(_ type: String, payload: JSONValue) -> [Effect] {
    let message = payload["message"].string ?? payload["error"].string ?? payload["text"].string ?? ""
    if type.contains(/(?i)error|fail/) {
      if HermesError.looksOwnedElsewhere(message) {
        // The turn never ran: take back the bubble, keep the words.
        var text = ""
        if let userIndex = items.lastIndex(where: { $0.kind == .user }) {
          let last = items.count - 1
          let emptyStream = last == userIndex + 1 && items[last].kind == .assistant && items[last].isStreaming && items[last].text.isEmpty
          if last == userIndex || emptyStream {
            text = items[userIndex].text
            items.removeSubrange(userIndex...)
          }
        }
        isStreaming = false
        status = ""
        return [.refused(message: message, text: text)]
      }
      isStreaming = false
      status = ""
      if let index = streamIndex { items[index].isStreaming = false }
      return [.failure(String((message.isEmpty ? type : message).prefix(300)))]
    }
    switch type {
    case "turn.end", "turn.complete", "session.idle":
      isStreaming = false
      status = ""
      if let index = streamIndex { items[index].isStreaming = false }
    case "notification", "notice":
      if !message.isEmpty { return [.notice(String(message.prefix(200)))] }
    default:
      break
    }
    return []
  }

  // MARK: Reconciling after a reconnect or a poll

  /// Folds a fresh copy of the transcript into what is on screen.
  ///
  /// When the fresh copy only extends what we have, the new tail is appended and existing
  /// items keep their identity (so the view does not re-render). A real divergence (undo,
  /// compression, edits from another device) replaces the settled items once.
  public mutating func reconcile(fresh: [TranscriptItem], inflight: JSONValue, turnStartedAt: Double? = nil, now: Double) {
    if let index = streamIndex { items.remove(at: index) }
    let settled = items.filter { !$0.isPending && !$0.isLocal }
    var common = 0
    while common < settled.count, common < fresh.count, settled[common].signature == fresh[common].signature {
      common += 1
    }
    if common == settled.count {
      for item in fresh[common...] {
        if item.kind == .user,
          let pendingIndex = items.firstIndex(where: { $0.isPending && !$0.hasLanded && $0.signature == item.signature })
        {
          items[pendingIndex].hasLanded = true
          continue
        }
        items.append(item)
      }
    } else {
      var pending = items.filter(\.isPending)
      for index in pending.indices
      where fresh.contains(where: { $0.kind == .user && $0.signature == pending[index].signature }) {
        pending[index].hasLanded = true
      }
      items = fresh + pending.filter { !$0.hasLanded }
    }
    syncTools(with: fresh)
    applyInflight(inflight, turnStartedAt: turnStartedAt, now: now)
    if inflight.isNull { isStreaming = false }
  }

  /// Tool calls that finished elsewhere since the last look are completed in place.
  private mutating func syncTools(with fresh: [TranscriptItem]) {
    var finished: [String: ToolCall] = [:]
    for item in fresh { if let tool = item.tool, tool.isDone { finished[tool.callID] = tool } }
    guard !finished.isEmpty else { return }
    for index in items.indices {
      guard var tool = items[index].tool, !tool.isDone, let done = finished[tool.callID] else { continue }
      tool.isDone = true
      tool.result = done.result
      if !done.inlineDiff.isEmpty { tool.inlineDiff = done.inlineDiff }
      if let answers = done.answers { tool.answers = answers }
      tool.pendingRequest = nil
      items[index].tool = tool
    }
  }

  // MARK: Questions

  /// Attaches a clarify request to its tool row, creating the row when the request arrives first.
  public mutating func attach(clarify request: ServerRequest) {
    if items.contains(where: { $0.tool?.pendingRequest?.id == request.id }) { return }
    let asked = ClarifyQuestion.list(from: request.params["questions"])
    func normalized(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    let match = items.lastIndex { item in
      guard let tool = item.tool, tool.isClarify, !tool.isDone, tool.pendingRequest == nil else { return false }
      let own = tool.questions
      return own.isEmpty || normalized(own.first?.question) == normalized(asked.first?.question)
    }
    if let match {
      items[match].tool?.pendingRequest = request
      items[match].tool?.isCancelled = false
    } else {
      var call = ToolCall(callID: "ask-\(request.id)", name: "clarify", args: ["questions": request.params["questions"]])
      call.pendingRequest = request
      items.append(.tool(call))
    }
  }

  /// Records the answers the user gave and returns the JSON-RPC result to send back.
  public mutating func answer(clarifyRequestID: String, values: [[String]?]) -> (request: ServerRequest, result: JSONValue)? {
    guard let index = items.firstIndex(where: { $0.tool?.pendingRequest?.id == clarifyRequestID }),
      var tool = items[index].tool, let request = tool.pendingRequest
    else { return nil }
    let questions = tool.questions
    var answers: [String: JSONValue] = [:]
    var recorded: [ClarifyAnswer] = []
    for (offset, question) in questions.enumerated() {
      let picked = offset < values.count ? values[offset] : nil
      let chosen = picked ?? []
      if chosen.isEmpty {
        answers[question.qid] = .null
      } else if question.multiSelect {
        answers[question.qid] = .array(chosen.map(JSONValue.string))
      } else {
        answers[question.qid] = .string(chosen[0])
      }
      recorded.append(ClarifyAnswer(values: chosen, skipped: chosen.isEmpty, question: question.question))
    }
    // Keep the questions on the row: they came with the request, which is about to be cleared.
    tool.args = ["questions": request.params["questions"]]
    tool.pendingRequest = nil
    tool.answers = recorded
    items[index].tool = tool
    return (request, ["answers": .object(answers)])
  }
}

/// What a running turn is doing, in the words the transcript shows.
public enum TurnActivity: Sendable, Equatable {
  /// The model is working out what to do next.
  case thinking
  /// A tool call has started and not finished.
  case running(ToolCall)
  /// Text is streaming in: a note between steps, or the answer.
  case writing
  /// The agent asked a question and is waiting for the answer.
  case waiting

  /// What a turn is doing, read from its stored transcript. For a chat another Hermes process is
  /// running, where no events reach this app: a tool call without a result is still running.
  public static func inferred(from items: [TranscriptItem]) -> TurnActivity {
    guard let last = items.last else { return .thinking }
    if let tool = last.tool, !tool.isDone { return tool.isClarify ? .waiting : .running(tool) }
    return .thinking
  }

  /// When the running turn began: the time of the last thing the user sent.
  public static func turnStart(in items: [TranscriptItem]) -> Double? {
    items.last { $0.kind == .user }?.timestamp
  }
}
