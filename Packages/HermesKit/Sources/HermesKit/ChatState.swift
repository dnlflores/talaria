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
    var anchor: Int?
    let corrections = (inflight["corrections"].array ?? []).compactMap(\.string).filter { !$0.isEmpty }
      .map { TranscriptItem.user($0, timestamp: now) }
    let correctionSignatures = Set(corrections.map(\.signature))
    if let user = inflight["user"].string, !user.isEmpty, inflight["display_kind"].stringValue.isEmpty {
      let incoming = TranscriptItem.user(user, timestamp: now)
      // A message sent into this reply may already sit after the turn's own message.
      let known = items.lastIndex { $0.kind == .user && !correctionSignatures.contains($0.signature) }.map { index in
        items[index].signature == incoming.signature && isCurrentTurnMessage(at: index, turnStartedAt: turnStartedAt)
      } ?? false
      if !known { items.append(incoming) }
      anchor = items.lastIndex { $0.kind == .user && $0.signature == incoming.signature }
    }
    // Messages sent into this reply while it ran. The history stores them only once the turn ends.
    let first = anchor ?? items.lastIndex(where: { $0.kind == .user })
    if let first {
      for incoming in corrections
      where !items[first...].contains(where: { $0.kind == .user && $0.signature == incoming.signature }) {
        items.append(incoming)
      }
    }
    // `assistant` is everything the turn has streamed, the steps already settled included (also
    // those before a message sent into it); the history holds those steps as their own messages,
    // so only what follows them is still open.
    let turnStart = first.map { $0 + 1 } ?? 0
    let settled = items[turnStart...].filter { $0.kind == .assistant }.map(\.text)
    let partial = ChatState.unsettledText(inflight["assistant"].stringValue, settled: settled)
    // A call that is running is what the turn is doing; an empty text after it would say "Thinking".
    let callRunning = items.last?.tool.map { !$0.isDone } ?? false
    if !partial.isEmpty || (streaming && !callRunning) {
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

  /// The Mac started the turn for messages handed to its queue: they show as the message that
  /// started it. Text-only messages queued together run as one turn, joined by blank lines.
  public mutating func beginHandedOverTurn(texts: [String], now: Double) {
    let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    guard !text.isEmpty else { return }
    settleStream()
    items.append(TranscriptItem(kind: .user, text: text, timestamp: now))
  }

  /// Whether a message with these words is in the transcript, alone or joined with others.
  public func hasUserMessage(_ text: String) -> Bool {
    let wanted = ChatState.normalized(text)
    guard !wanted.isEmpty else { return true }
    return items.contains { $0.kind == .user && ChatState.normalized($0.text).contains(wanted) }
  }

  /// Words with runs of whitespace made single spaces, for comparing messages.
  public static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// A message the running reply took in mid-turn (`session.redirect` said `redirected`). It goes
  /// where it arrived: after what has streamed so far, before what the reply does next. The turn
  /// keeps running.
  public mutating func insertCorrection(_ text: String, now: Double) {
    settleStream()
    preparingTool = nil
    items.append(TranscriptItem(kind: .user, text: text, timestamp: now))
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

    case "prompt.settled":
      // A question every viewer saw was answered (here, or on the desktop) or given up on. Its
      // answer arrives with the call's result, so the row only stops waiting here.
      guard let requestID = payload["id"].scalarText else { break }
      if let index = items.firstIndex(where: { $0.tool?.pendingRequest?.id == requestID }) {
        items[index].tool?.pendingRequest = nil
      }
      return [.requestCancelled(requestID)]

    case "session.updated":
      // Another viewer changed the chat (the desktop renamed it, switched its model, ...).
      if payload["operation"].string == "rename", let value = payload["title"].string, !value.isEmpty { title = value }
      if payload["operation"].string == "model", let model = payload["model"].string, !model.isEmpty { info.model = model }

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
    let settledIndices = items.indices.filter { !items[$0].isPending && !items[$0].isLocal }
    var common = 0
    while common < settledIndices.count, common < fresh.count,
      items[settledIndices[common]].signature == fresh[common].signature
    {
      let index = settledIndices[common]
      // Matching words keep their identity, but the stored projection determines their role.
      if items[index].kind == .assistant { items[index].isCommentary = fresh[common].isCommentary }
      // ... and the stored row names which turn a message is.
      if let rowID = fresh[common].rowID { items[index].rowID = rowID }
      common += 1
    }
    if common == settledIndices.count {
      for item in fresh[common...] {
        if item.kind == .user,
          let pendingIndex = items.firstIndex(where: { $0.isPending && !$0.hasLanded && $0.signature == item.signature })
        {
          items[pendingIndex].hasLanded = true
          if let rowID = item.rowID { items[pendingIndex].rowID = rowID }
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

  /// Puts a fresh copy of the transcript in place of what is on screen, keeping messages typed
  /// here that it does not hold yet.
  public mutating func replace(with fresh: [TranscriptItem], inflight: JSONValue, turnStartedAt: Double? = nil, now: Double) {
    if let index = streamIndex { items.remove(at: index) }
    let pending = items.filter { item in
      item.isPending && !fresh.contains { $0.kind == .user && $0.signature == item.signature }
    }
    items = fresh + pending
    applyInflight(inflight, turnStartedAt: turnStartedAt, now: now)
    if inflight.isNull { isStreaming = false }
  }

  /// Folds the newest page of the stored transcript into what is on screen, when only that page
  /// was read and older items may be held above it.
  ///
  /// The page has to line up with the end of what is held: either the held items run on into
  /// the page, or the page reaches back past all of them. What it adds goes on the end; items
  /// already held keep their identity. Returns false, touching nothing, when the page does not
  /// line up (more happened than one page shows, or the conversation changed elsewhere): then the
  /// caller replaces the transcript with the page.
  public mutating func reconcileTail(fresh: [TranscriptItem], inflight: JSONValue, turnStartedAt: Double? = nil, now: Double) -> Bool {
    var next = self
    if let index = next.streamIndex { next.items.remove(at: index) }
    let settledIndices = next.items.indices.filter { !next.items[$0].isPending && !next.items[$0].isLocal }
    let held = settledIndices.map { next.items[$0].signature }
    guard let start = ChatState.alignment(held: held, page: fresh.map(\.signature)) else { return false }
    let overlap = min(settledIndices.count, start)
    for offset in 0..<overlap {
      let index = settledIndices[settledIndices.count - overlap + offset]
      if next.items[index].kind == .assistant {
        next.items[index].isCommentary = fresh[start - overlap + offset].isCommentary
      }
      if let rowID = fresh[start - overlap + offset].rowID { next.items[index].rowID = rowID }
    }
    for item in fresh[start...] {
      if item.kind == .user,
        let pendingIndex = next.items.firstIndex(where: { $0.isPending && !$0.hasLanded && $0.signature == item.signature })
      {
        next.items[pendingIndex].hasLanded = true
        if let rowID = item.rowID { next.items[pendingIndex].rowID = rowID }
        continue
      }
      next.items.append(item)
    }
    next.syncTools(with: fresh)
    next.applyInflight(inflight, turnStartedAt: turnStartedAt, now: now)
    if inflight.isNull { next.isStreaming = false }
    self = next
    return true
  }

  /// Where the new part of `page` begins, when the end of `held` lines up with it; nil when it
  /// does not. The longest overlap wins: all of `held` inside the page (its last place there),
  /// else the longest run at the end of `held` that begins the page.
  static func alignment(held: [String], page: [String]) -> Int? {
    if held.isEmpty { return 0 }
    if page.isEmpty { return nil }
    // The page reaches back past everything held.
    if held.count <= page.count {
      for offset in stride(from: page.count - held.count, through: 0, by: -1)
      where page[offset..<(offset + held.count)].elementsEqual(held) {
        return offset + held.count
      }
    }
    // The page starts inside what is held.
    for start in max(1, held.count - page.count)..<held.count {
      let overlap = held.count - start
      if held[start...].elementsEqual(page[..<overlap]) { return overlap }
    }
    return nil
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
