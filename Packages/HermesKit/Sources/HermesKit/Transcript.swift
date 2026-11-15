import Foundation

public struct ClarifyQuestion: Sendable, Equatable {
  public var qid: String
  public var question: String
  public var choices: [String]
  public var multiSelect: Bool

  /// Questions as the gateway sends them: objects, or bare strings from older tool calls.
  public static func list(from json: JSONValue) -> [ClarifyQuestion] {
    (json.array ?? []).enumerated().map { index, item in
      if let text = item.string {
        return ClarifyQuestion(qid: String(index), question: text, choices: [], multiSelect: false)
      }
      return ClarifyQuestion(
        qid: item["qid"].scalarText ?? String(index),
        question: item["question"].stringValue,
        choices: (item["choices"].array ?? []).compactMap(\.scalarText),
        multiSelect: item["multi_select"].truthy)
    }
  }
}

public struct ClarifyAnswer: Sendable, Equatable {
  public var values: [String]
  public var skipped: Bool
  public var question: String?

  public init(values: [String], skipped: Bool, question: String? = nil) {
    self.values = values
    self.skipped = skipped
    self.question = question
  }

  /// Reads the answers out of a stored clarify tool result. The shape changed across
  /// Hermes versions: a `responses` list, an `answers` map, or prose after compaction.
  public static func parse(_ raw: String, questionCount: Int) -> [ClarifyAnswer]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if let json = try? JSONValue.parse(trimmed), json.object != nil {
      var responses = json["responses"].array
      if responses == nil, !json["user_response"].isNull || !json["answer"].isNull { responses = [json] }
      if let responses {
        return responses.map { item in
          let value = item["user_response"].isNull ? item["answer"] : item["user_response"]
          let status = item["status"].string
          return ClarifyAnswer(
            values: strings(value), skipped: (status != nil && status != "answered") || value.isNull,
            question: item["question"].string)
        }
      }
      if let answers = json["answers"].object {
        return answers.keys.sorted().map { key in
          let value = answers[key] ?? .null
          return ClarifyAnswer(values: strings(value), skipped: value.isNull)
        }
      }
    }
    if let match = trimmed.firstMatch(of: /(?i)user responded:\s*"((?s).*)"\s*$/) {
      return [ClarifyAnswer(values: [String(match.1)], skipped: false)]
    }
    if let match = trimmed.firstMatch(of: /(?i)user responded:\s*((?s).+)$/) {
      return [ClarifyAnswer(values: [String(match.1)], skipped: false)]
    }
    if trimmed.contains(/(?i)skipp|cancel|no response|did not (answer|respond)|timed out/) {
      return Array(repeating: ClarifyAnswer(values: [], skipped: true), count: max(questionCount, 1))
    }
    return [ClarifyAnswer(values: [String(trimmed.prefix(400))], skipped: false)]
  }

  private static func strings(_ value: JSONValue) -> [String] {
    if let list = value.array { return list.compactMap(\.scalarText) }
    if let text = value.scalarText { return [text] }
    return []
  }
}

public struct ToolCall: Sendable, Equatable, Identifiable {
  public var id: String { callID }
  public var callID: String
  public var name: String
  public var context: String
  public var args: JSONValue
  public var isDone: Bool
  public var summary = ""
  public var duration: Double?
  public var result = ""
  public var isError = false
  /// ANSI-colored unified diff the backend attaches to file edits.
  public var inlineDiff = ""
  /// Set while the gateway is waiting for this question to be answered.
  public var pendingRequest: ServerRequest?
  public var answers: [ClarifyAnswer]?
  public var isCancelled = false

  /// One line saying what the call works on: the backend's context line, else its summary, else
  /// the main argument. Calls read back from stored rows carry only their arguments.
  public var preview: String {
    let text: String
    if !context.isEmpty {
      text = context
    } else if !summary.isEmpty {
      text = summary
    } else {
      let keys = ["command", "path", "query", "url", "pattern", "code", "goal", "name"]
      text = keys.lazy.compactMap { self.args[$0].string }.first { !$0.isEmpty } ?? ""
    }
    let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return line.count > 160 ? String(line.prefix(159)) + "…" : line
  }

  /// A tool's name as the rest of the stream names it: `tool.generating` reports Claude's
  /// `mcp__terminal` for the `terminal` that `tool.start` then reports.
  public static func displayName(_ raw: String) -> String {
    guard raw.hasPrefix("mcp__") else { return raw.isEmpty ? "tool" : raw }
    let rest = String(raw.dropFirst(5))
    return rest.contains("__") || rest.isEmpty ? raw : rest
  }

  public init(callID: String, name: String, context: String = "", args: JSONValue = .null, isDone: Bool = false) {
    self.callID = callID
    self.name = name
    self.context = context
    self.args = args
    self.isDone = isDone
  }

  public var isClarify: Bool { name == "clarify" }

  public var questions: [ClarifyQuestion] {
    if let pendingRequest { return ClarifyQuestion.list(from: pendingRequest.params["questions"]) }
    let parsed = args.parsedIfJSONString
    if parsed["questions"].array != nil { return ClarifyQuestion.list(from: parsed["questions"]) }
    if let question = parsed["question"].string {
      return [ClarifyQuestion(
        qid: "0", question: question, choices: (parsed["choices"].array ?? []).compactMap(\.scalarText),
        multiSelect: parsed["multi_select"].truthy)]
    }
    return []
  }
}

public struct AttachmentChip: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable { case image, file }
  public let id: UUID
  public var kind: Kind
  public var name: String
  /// Small JPEG for the bubble; the full image is uploaded separately.
  public var thumbnail: Data?

  public init(id: UUID = UUID(), kind: Kind, name: String, thumbnail: Data? = nil) {
    self.id = id
    self.kind = kind
    self.name = name
    self.thumbnail = thumbnail
  }
}

/// One entry of a conversation as the app shows it.
public struct TranscriptItem: Identifiable, Sendable, Equatable {
  /// `side`: a `/btw` or `/bg` sent from here, or its answer (`SideTask`).
  public enum Kind: Sendable, Equatable { case user, assistant, tool, system, side }

  public let id: UUID
  public var kind: Kind
  public var text: String
  /// What actually went to the backend when it differs from `text` (file refs appended).
  public var sentText: String?
  public var reasoning = ""
  /// The gateway explicitly projected these words as public progress, not a final answer.
  public var isCommentary = false
  /// Seconds since 1970.
  public var timestamp: Double?
  public var isStreaming = false
  /// A user message that was typed here and is not acknowledged yet.
  public var isPending = false
  public var isFailed = false
  /// The backend's transcript already contains this pending message.
  public var hasLanded = false
  /// Shown only in this app (the output of a command, for example); never part of the stored transcript.
  public var isLocal = false
  /// The `/command` a local notice answers (`/usage`).
  public var command = ""
  public var tool: ToolCall?
  /// A side question or background task, for `side` items.
  public var side: SideTask?
  public var attachments: [AttachmentChip] = []
  /// Pictures the message carries, as paths on the Mac (`@image:` lines, lifted out of `text`).
  public var images: [String] = []

  public init(id: UUID = UUID(), kind: Kind, text: String = "", timestamp: Double? = nil) {
    self.id = id
    self.kind = kind
    self.text = text
    self.timestamp = timestamp
  }

  public static func tool(_ call: ToolCall, timestamp: Double? = nil) -> TranscriptItem {
    var item = TranscriptItem(kind: .tool, timestamp: timestamp)
    item.tool = call
    return item
  }

  /// Identity for matching what is on screen against a fresh copy of the transcript.
  public var signature: String {
    switch kind {
    case .tool: return "tool\u{1}" + (tool?.name ?? "")
    default:
      let body = (sentText ?? text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
      return "\(kind)\u{1}\(body)"
    }
  }
}

// MARK: - Building items from the backend's two transcript shapes

extension TranscriptItem {
  /// Seconds or milliseconds, as a number or numeric string.
  static func seconds(_ value: JSONValue) -> Double? {
    guard let number = value.double, number > 0 else { return nil }
    return number > 1e11 ? number / 1000 : number
  }

  static func text(_ content: JSONValue) -> String {
    if let text = content.string { return text }
    if let parts = content.array {
      return parts.compactMap { part in part["type"].string == "text" || part["type"].isNull ? part["text"].string : nil }
        .joined(separator: "\n")
    }
    return ""
  }

  static func inlineDiff(_ metadata: JSONValue) -> String {
    let parsed = metadata.parsedIfJSONString
    return parsed["tool_result_metadata"]["inline_diff"].string ?? parsed["inline_diff"].string ?? ""
  }

  /// A user message: what the person wrote, with the pictures it carries lifted out.
  public static func user(_ raw: String, timestamp: Double?) -> TranscriptItem {
    let content = UserContent(raw)
    var item = TranscriptItem(kind: .user, text: content.text, timestamp: timestamp)
    item.images = content.images
    return item
  }

  /// Kinds of user row that hold what the person wrote: a plain message, a skill they invoked, and
  /// a message they sent into a running reply (`steer`). Other kinds are notices Hermes wrote.
  static let userKinds: Set<String> = ["", "skill_invocation", "steer"]
  /// Model-facing wake receipts are not messages from the person or the agent.
  static let machineryKinds: Set<String> = ["internal_notification", "process_complete", "async_delegation_complete"]

  /// Both history shapes carry the gateway's safe Codex display projection. Never recover
  /// words from raw provider sidecars, or fall back when an explicitly projected field is empty.
  private static func assistantItems(_ message: JSONValue, body: String, timestamp: Double?) -> [TranscriptItem] {
    guard message["display_kind"].string != "hidden" else { return [] }
    let reasoning = message["display_reasoning"].string
      ?? message["reasoning"].string.flatMap { $0.isEmpty ? nil : $0 }
      ?? message["reasoning_content"].stringValue
    var items: [TranscriptItem] = []
    for words in message["display_commentary"].array ?? [] {
      guard let words = words.string, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      var item = TranscriptItem(kind: .assistant, text: words, timestamp: timestamp)
      if items.isEmpty { item.reasoning = reasoning }
      item.isCommentary = true
      items.append(item)
    }
    if !body.isEmpty || items.isEmpty {
      var item = TranscriptItem(kind: .assistant, text: body, timestamp: timestamp)
      if items.isEmpty { item.reasoning = reasoning }
      items.append(item)
    }
    return items
  }

  /// The note Hermes writes when it picks up a turn that was cut off; older rows carry no kind.
  static let autoContinueNote = "[System note: Your previous turn was interrupted mid-run"

  /// The display projection `session.resume` returns: user/assistant text plus finished tool rows.
  public static func items(fromHistory messages: [JSONValue]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    for message in messages {
      let timestamp = seconds(message["timestamp"])
      switch message["role"].stringValue {
      case "tool":
        var call = ToolCall(
          callID: message["tool_call_id"].scalarText ?? UUID().uuidString,
          name: message["name"].string ?? "tool", context: message["context"].stringValue,
          args: message["args"], isDone: true)
        call.result = message["content"].scalarText ?? ""
        call.inlineDiff = inlineDiff(message["display_metadata"])
        items.append(.tool(call, timestamp: timestamp))
      case "user":
        // Hidden rows are scaffolding for the model; the desktop app leaves them out too.
        let displayKind = message["display_kind"].string ?? ""
        if displayKind == "hidden" || machineryKinds.contains(displayKind) { continue }
        if userKinds.contains(displayKind) {
          items.append(.user(message["text"].stringValue, timestamp: timestamp))
        } else {
          items.append(TranscriptItem(kind: .system, text: message["text"].stringValue, timestamp: timestamp))
        }
      case "assistant":
        items.append(contentsOf: assistantItems(message,
          body: message["display_content"].string ?? message["text"].stringValue, timestamp: timestamp))
      default:
        continue
      }
    }
    return items
  }

  /// The Mac writes a message queued behind a running reply into its history at once, right
  /// after the reply's own message, and moves it to the end when its turn starts. Until then it is
  /// not part of the conversation: these rows come out, so the running reply stays under the
  /// message that started it. Only rows with the words of `queued` are touched.
  public static func withoutEarlyQueued(
    _ items: [TranscriptItem], queued: [String], runningUser: String?, turnStartedAt: Double?
  ) -> [TranscriptItem] {
    let wanted = Set((queued + [queued.joined(separator: "\n\n")]).map(ChatState.normalized).filter { !$0.isEmpty })
    guard !wanted.isEmpty else { return items }
    let anchor = runningUser.flatMap { user -> Int? in
      let signature = TranscriptItem.user(user, timestamp: nil).signature
      return items.lastIndex { $0.kind == .user && $0.signature == signature && !wanted.contains(ChatState.normalized($0.text)) }
    }
    var out: [TranscriptItem] = []
    for (index, item) in items.enumerated() {
      let isQueuedWords = item.kind == .user && wanted.contains(ChatState.normalized(item.text))
      let isAfterTurnStart: Bool
      if let anchor {
        isAfterTurnStart = index > anchor
      } else if let start = turnStartedAt, let stamp = item.timestamp {
        isAfterTurnStart = stamp > start
      } else {
        isAfterTurnStart = false
      }
      if isQueuedWords, isAfterTurnStart { continue }
      out.append(item)
    }
    return out
  }

  /// Raw stored rows (`GET /api/sessions/{id}/messages`): assistant rows carry their tool calls,
  /// tool rows carry results. A call with no result row is still running wherever the chat is open.
  ///
  /// Shown the way `session.resume` shows them (`tui_gateway/session_history.py`): notices Hermes
  /// wrote (a finished background process, a model switch) are system lines, a `/skill` turn shows
  /// as its invocation, and `[System:` markers and hidden rows are left out.
  /// Rows must start where a turn or a step starts: a result whose call is in an earlier row is
  /// dropped (`HistoryPage` keeps pages to that).
  public static func items(fromStoredRows rows: [JSONValue]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    var callIndex: [String: Int] = [:]
    for row in rows {
      let timestamp = seconds(row["timestamp"])
      let displayKind = row["display_kind"].string ?? ""
      switch row["role"].stringValue {
      case "user":
        if displayKind == "hidden" || machineryKinds.contains(displayKind) { continue }
        let raw = row["display_content"].string.flatMap { $0.isEmpty ? nil : $0 } ?? text(row["content"])
        var body = UserContent.unwrappingOutOfBand(raw)
        if body.isEmpty { continue }
        // Bracketed `[System` rows are Hermes talking to the model; the one about picking up a
        // turn that was cut off is worth a line in the transcript.
        if body.trimmingCharacters(in: .whitespaces).hasPrefix("[System") {
          if body.trimmingCharacters(in: .whitespaces).hasPrefix(autoContinueNote) {
            items.append(TranscriptItem(kind: .system, text: body, timestamp: timestamp))
          }
          continue
        }
        if let invocation = SkillInvocation.text(body) { body = invocation }
        if userKinds.contains(displayKind) {
          items.append(.user(body, timestamp: timestamp))
        } else {
          items.append(TranscriptItem(kind: .system, text: body, timestamp: timestamp))
        }
      case "assistant":
        let shown = row["display_content"].string ?? text(row["content"])
        // A hidden row's words are for the model; its calls still show.
        items.append(contentsOf: assistantItems(row, body: shown, timestamp: timestamp)
          .filter { !$0.text.isEmpty || !$0.reasoning.isEmpty })
        for call in row["tool_calls"].parsedIfJSONString.array ?? [] {
          let callID = call["id"].scalarText ?? call["call_id"].scalarText ?? UUID().uuidString
          let arguments = call["function"]["arguments"].isNull ? call["arguments"] : call["function"]["arguments"]
          let tool = ToolCall(
            callID: callID, name: call["function"]["name"].string ?? call["name"].string ?? "tool",
            args: arguments.parsedIfJSONString)
          callIndex[callID] = items.count
          items.append(.tool(tool, timestamp: timestamp))
        }
      case "tool":
        guard let callID = row["tool_call_id"].scalarText, let index = callIndex[callID], var tool = items[index].tool else { continue }
        tool.isDone = true
        tool.result = text(row["content"])
        tool.inlineDiff = inlineDiff(row["display_metadata"])
        if tool.isClarify { tool.answers = ClarifyAnswer.parse(tool.result, questionCount: tool.questions.count) }
        items[index].tool = tool
      default:
        continue
      }
    }
    return items
  }
}
