import Foundation

/// The open conversation: its transcript and live status, advanced by gateway events.
///
/// This is a value type with no I/O so the event handling can be tested against recorded
/// sequences. The rules mirror the hermesdash web client, which is the reference
/// implementation this app was ported from.
public struct ChatState: Sendable, Equatable {
  public var items: [TranscriptItem] = []
  public var isStreaming = false
  /// The short "what it is doing" line the backend sends between tokens.
  public var status = ""
  public var info = SessionInfo()
  public var title = ""

  public init() {}

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
  /// `skippingKnownUser` is for reconciling: the in-flight user message may already be on
  /// screen, so it is added only when the last user message differs.
  public mutating func applyInflight(_ inflight: JSONValue, now: Double, skippingKnownUser: Bool = false) {
    guard !inflight.isNull else { return }
    let streaming = inflight["streaming"].truthy
    if let user = inflight["user"].string, !user.isEmpty, inflight["display_kind"].stringValue.isEmpty {
      let incoming = TranscriptItem(kind: .user, text: user, timestamp: now)
      let lastUser = items.last { $0.kind == .user }
      if !skippingKnownUser || lastUser?.signature != incoming.signature { items.append(incoming) }
    }
    let partial = inflight["assistant"].stringValue
    if !partial.isEmpty || streaming {
      var item = TranscriptItem(kind: .assistant, text: partial, timestamp: now)
      item.isStreaming = streaming
      items.append(item)
    }
    isStreaming = streaming
  }

  // MARK: Events

  @discardableResult
  public mutating func apply(event type: String, payload: JSONValue, now: Double) -> [Effect] {
    switch type {
    case "message.start":
      _ = ensureStream(now: now)
      isStreaming = true
      status = ""

    case "message.delta":
      let index = ensureStream(now: now)
      items[index].text += payload["text"].stringValue
      isStreaming = true
      status = ""

    case "reasoning.delta":
      let index = ensureStream(now: now)
      items[index].reasoning += payload["text"].stringValue

    case "thinking.delta":
      status = payload["text"].stringValue

    case "message.interim":
      let text = payload["text"].stringValue
      if let index = streamIndex {
        if !text.isEmpty { items[index].text = text }
        items[index].isStreaming = false
      } else if !text.isEmpty {
        items.append(TranscriptItem(kind: .assistant, text: text, timestamp: now))
      }

    case "tool.start":
      if let index = streamIndex {
        if items[index].text.isEmpty, items[index].reasoning.isEmpty {
          items.remove(at: index)
        } else {
          items[index].isStreaming = false
        }
      }
      let call = ToolCall(
        callID: payload["tool_id"].scalarText ?? UUID().uuidString, name: payload["name"].string ?? "tool",
        context: payload["context"].stringValue, args: payload["args"])
      items.append(.tool(call, timestamp: now))
      status = ""

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
  public mutating func reconcile(fresh: [TranscriptItem], inflight: JSONValue, now: Double) {
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
    applyInflight(inflight, now: now, skippingKnownUser: true)
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
