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
  public enum Kind: Sendable, Equatable { case user, assistant, tool, system }

  public let id: UUID
  public var kind: Kind
  public var text: String
  /// What actually went to the backend when it differs from `text` (file refs appended).
  public var sentText: String?
  public var reasoning = ""
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
  public var tool: ToolCall?
  public var attachments: [AttachmentChip] = []

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
        let displayKind = message["display_kind"].string ?? ""
        let isSystem = !displayKind.isEmpty && displayKind != "skill_invocation"
        items.append(TranscriptItem(kind: isSystem ? .system : .user, text: message["text"].stringValue, timestamp: timestamp))
      case "assistant":
        var item = TranscriptItem(kind: .assistant, text: message["text"].stringValue, timestamp: timestamp)
        item.reasoning = message["reasoning"].string ?? message["reasoning_content"].string ?? ""
        items.append(item)
      default:
        continue
      }
    }
    return items
  }

  /// Raw stored rows (`GET /api/sessions/{id}/messages`): assistant rows carry their tool calls,
  /// tool rows carry results. A call with no result row is still running wherever the chat is open.
  public static func items(fromStoredRows rows: [JSONValue]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    var callIndex: [String: Int] = [:]
    for row in rows {
      let timestamp = seconds(row["timestamp"])
      switch row["role"].stringValue {
      case "user":
        let body = text(row["content"])
        if !body.isEmpty, !body.hasPrefix("[System") {
          items.append(TranscriptItem(kind: .user, text: body, timestamp: timestamp))
        }
      case "assistant":
        let shown = row["display_content"].string.flatMap { $0.isEmpty ? nil : $0 } ?? text(row["content"])
        if !shown.isEmpty {
          var item = TranscriptItem(kind: .assistant, text: shown, timestamp: timestamp)
          item.reasoning = row["reasoning"].stringValue
          items.append(item)
        }
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
