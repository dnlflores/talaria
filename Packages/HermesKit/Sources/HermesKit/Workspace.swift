import Foundation

// MARK: - Files

/// What `/api/fs/read-text` returns: the head of a file as text, for a preview.
public struct FilePreview: Sendable, Equatable {
  public let path: String
  public let text: String
  public let isBinary: Bool
  public let byteSize: Int
  public let language: String
  public let mimeType: String
  /// Only the first part of the file came back.
  public let isTruncated: Bool

  public init(json: JSONValue) {
    path = json["path"].stringValue
    text = json["text"].stringValue
    isBinary = json["binary"].truthy
    byteSize = json["byteSize"].int ?? 0
    language = json["language"].stringValue
    mimeType = json["mimeType"].stringValue
    isTruncated = json["truncated"].truthy
  }
}

// MARK: - Cron

/// A scheduled job from `GET /api/cron/jobs`.
public struct CronJob: Identifiable, Sendable, Equatable {
  public let id: String
  public var name: String
  public var prompt: String
  public var profile: String
  public var schedule: String
  public var scheduleDisplay: String
  public var state: String
  public var isEnabled: Bool
  public var isScript: Bool
  public var script: String
  public var model: String
  public var deliver: String
  public var nextRunAt: Date?
  public var lastRunAt: Date?
  public var createdAt: Date?
  public var pausedAt: Date?
  public var pausedReason: String
  public var lastStatus: String
  public var lastError: String
  public var lastDeliveryError: String
  public var completedRuns: Int
  /// Runs before the job completes; `nil` repeats forever.
  public var repeatTimes: Int?
  public var failureStreak: Int
  /// A run is executing right now.
  public var isRunning: Bool

  public init(json: JSONValue) {
    id = json["id"].stringValue
    name = json["name"].stringValue
    prompt = json["prompt"].stringValue
    profile = json["profile"].string ?? json["profile_name"].string ?? "default"
    schedule = json["schedule"]["expr"].string ?? json["schedule"].string ?? ""
    scheduleDisplay = json["schedule_display"].string ?? json["schedule"]["display"].stringValue
    state = json["state"].stringValue.lowercased()
    isEnabled = json["enabled"].bool ?? true
    isScript = json["no_agent"].truthy
    script = json["script"].stringValue
    model = json["model"].stringValue
    deliver = json["deliver"].stringValue
    nextRunAt = CronJob.date(json["next_run_at"])
    lastRunAt = CronJob.date(json["last_run_at"])
    createdAt = CronJob.date(json["created_at"])
    pausedAt = CronJob.date(json["paused_at"])
    pausedReason = json["paused_reason"].stringValue
    lastStatus = json["last_status"].stringValue.lowercased()
    lastError = json["last_error"].stringValue
    lastDeliveryError = json["last_delivery_error"].stringValue
    completedRuns = json["repeat"]["completed"].int ?? 0
    repeatTimes = json["repeat"]["times"].int
    failureStreak = json["failure_streak"].int ?? 0
    isRunning = !json["live_execution"].isNull || state == "running"
  }

  public var isPaused: Bool { !isEnabled || state == "paused" }
  public var isCompleted: Bool { state == "completed" || state == "done" }
  public var lastRunFailed: Bool { ["error", "failed", "failure", "timeout"].contains(lastStatus) || failureStreak > 0 }
  public var title: String { name.isEmpty ? String(prompt.prefix(60)) : name }

  /// ISO 8601 with or without fractional seconds (the backend writes microseconds), or epoch seconds.
  static func date(_ value: JSONValue) -> Date? {
    if let seconds = value.double, seconds > 0 { return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds) }
    guard let text = value.string, !text.isEmpty else { return nil }
    let plain = text.replacing(/\.\d+/, with: "")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: plain)
  }
}

/// One past run of a cron job (`GET /api/cron/jobs/{id}/runs`). Agent runs are chats; script
/// runs only leave an output file.
public struct CronRun: Identifiable, Sendable, Equatable {
  public let id: String
  public var title: String
  public var preview: String
  public var source: String
  public var startedAt: Double
  public var endedAt: Double
  public var model: String
  public var messageCount: Int
  public var toolCallCount: Int

  public init(json: JSONValue) {
    id = json["id"].stringValue
    title = json["title"].stringValue
    preview = json["preview"].stringValue
    source = json["source"].stringValue
    startedAt = json["started_at"].double ?? 0
    endedAt = json["ended_at"].double ?? 0
    model = json["model"].stringValue
    messageCount = json["message_count"].int ?? 0
    toolCallCount = json["tool_call_count"].int ?? 0
  }

  /// The run is a stored chat that can be opened.
  public var isChat: Bool { source != "cron_output" && !id.hasPrefix("cron_output:") }

  /// "Completed", "Failed" and the like, read off the front of the title the backend writes.
  public var outcome: String {
    guard let dot = title.range(of: " · ") else { return "" }
    let word = title[..<dot.lowerBound].trimmingCharacters(in: .whitespaces)
    return word.count <= 16 ? word.capitalized : ""
  }
}

// MARK: - Kanban

public struct KanbanBoardSummary: Identifiable, Sendable, Equatable {
  public var id: String { slug }
  public let slug: String
  public var name: String
  public var isCurrent: Bool
  public var total: Int

  public init(json: JSONValue) {
    slug = json["slug"].stringValue
    name = json["name"].string ?? json["slug"].stringValue
    isCurrent = json["is_current"].truthy
    total = json["total"].int ?? 0
  }
}

public struct KanbanTask: Identifiable, Sendable, Equatable {
  public let id: String
  public var title: String
  public var body: String
  public var status: String
  public var assignee: String
  public var priority: Int
  public var createdAt: Double
  public var startedAt: Double
  public var completedAt: Double
  public var currentRunStartedAt: Double
  public var latestSummary: String
  public var commentCount: Int
  public var progressDone: Int?
  public var progressTotal: Int?
  public var blockKind: String
  public var warningCount: Int
  public var workspacePath: String
  public var branchName: String
  public var result: String
  public var lastFailureError: String
  public var modelOverride: String
  public var sessionID: String

  public init(json: JSONValue) {
    id = json["id"].stringValue
    title = json["title"].stringValue
    body = json["body"].stringValue
    status = json["status"].stringValue
    assignee = json["assignee"].stringValue
    priority = json["priority"].int ?? 0
    createdAt = json["created_at"].double ?? 0
    startedAt = json["started_at"].double ?? 0
    completedAt = json["completed_at"].double ?? 0
    currentRunStartedAt = json["current_run_started_at"].double ?? 0
    latestSummary = json["latest_summary"].stringValue
    commentCount = json["comment_count"].int ?? 0
    progressDone = json["progress"]["done"].int
    progressTotal = json["progress"]["total"].int
    blockKind = json["block_kind"].stringValue
    warningCount = json["warnings"]["count"].int ?? 0
    workspacePath = json["workspace_path"].stringValue
    branchName = json["branch_name"].stringValue
    result = json["result"].scalarText ?? ""
    lastFailureError = json["last_failure_error"].stringValue
    modelOverride = json["model_override"].stringValue
    sessionID = json["session_id"].stringValue
  }

  /// The newest sign of life, for ordering cards inside a column.
  public var recency: Double { max(completedAt, currentRunStartedAt, startedAt, createdAt) }
}

public struct KanbanColumn: Identifiable, Sendable, Equatable {
  public var id: String { name }
  public let name: String
  public var tasks: [KanbanTask]

  /// "In review" reads better than "review".
  public var label: String { KanbanColumn.label(for: name) }

  public static func label(for name: String) -> String {
    switch name {
    case "todo": return "To do"
    case "review": return "Review"
    default: return name.prefix(1).uppercased() + name.dropFirst().replacingOccurrences(of: "_", with: " ")
    }
  }
}

public struct KanbanBoard: Sendable, Equatable {
  public var columns: [KanbanColumn]
  public var assignees: [String]
  public var latestEventID: Int

  public init(json: JSONValue) {
    columns = (json["columns"].array ?? []).map { column in
      KanbanColumn(name: column["name"].stringValue, tasks: (column["tasks"].array ?? []).map(KanbanTask.init(json:)))
    }
    assignees = (json["assignees"].array ?? []).compactMap(\.string)
    latestEventID = json["latest_event_id"].int ?? 0
  }
}

public struct KanbanComment: Identifiable, Sendable, Equatable {
  public let id: String
  public var author: String
  public var body: String
  public var createdAt: Double

  public init(json: JSONValue) {
    id = json["id"].scalarText ?? UUID().uuidString
    author = json["author"].stringValue
    body = json["body"].stringValue
    createdAt = json["created_at"].double ?? 0
  }
}

public struct KanbanRun: Identifiable, Sendable, Equatable {
  public let id: String
  public var profile: String
  public var status: String
  public var outcome: String
  public var summary: String
  public var error: String
  public var startedAt: Double
  public var endedAt: Double
  /// The chat the worker ran in, when the run recorded one.
  public var sessionID: String

  public init(json: JSONValue) {
    id = json["id"].scalarText ?? UUID().uuidString
    profile = json["profile"].stringValue
    status = json["status"].stringValue
    outcome = json["outcome"].stringValue
    summary = json["summary"].stringValue
    error = json["error"].stringValue
    startedAt = json["started_at"].double ?? 0
    endedAt = json["ended_at"].double ?? 0
    let metadata = json["metadata"].parsedIfJSONString
    sessionID = metadata["session_id"].string ?? json["session_id"].stringValue
  }
}

public struct KanbanTaskDetail: Sendable, Equatable {
  public var task: KanbanTask
  public var comments: [KanbanComment]
  public var runs: [KanbanRun]
  public var parents: [KanbanLink]
  public var children: [KanbanLink]

  public struct KanbanLink: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var status: String
  }

  public init(json: JSONValue) {
    task = KanbanTask(json: json["task"])
    comments = (json["comments"].array ?? []).map(KanbanComment.init(json:))
    runs = (json["runs"].array ?? []).map(KanbanRun.init(json:))
    var titles: [String: (String, String)] = [:]
    for link in json["link_tasks"].array ?? [] {
      titles[link["id"].stringValue] = (link["title"].stringValue, link["status"].stringValue)
    }
    func links(_ key: String) -> [KanbanLink] {
      (json["links"][key].array ?? []).compactMap(\.string).map { id in
        KanbanLink(id: id, title: titles[id]?.0 ?? id, status: titles[id]?.1 ?? "")
      }
    }
    parents = links("parents")
    children = links("children")
  }
}

// MARK: - Calls

extension HermesClient {
  // MARK: Files

  /// The head of a file on the Mac as text. Relative paths resolve against the chat's working folder.
  public func filePreview(path: String, profile: String, storedID: String?) async throws -> FilePreview {
    var query = [("path", path), ("profile", profile)]
    if let storedID, !storedID.isEmpty { query.append(("session_id", storedID)) }
    return FilePreview(json: try await http.json("GET", "/api/fs/read-text", query: query, timeout: 45))
  }

  /// Copies a file from the Mac into this app's temporary folder and returns its local URL.
  public func downloadFile(path: String, profile: String, storedID: String?) async throws -> URL {
    var query = [("path", path), ("profile", profile)]
    if let storedID, !storedID.isEmpty { query.append(("session_id", storedID)) }
    let name = path.split(separator: "/").last.map(String.init) ?? "download"
    return try await http.download("/api/fs/download", query: query, suggestedName: name)
  }

  // MARK: Bots

  /// A bot's standing instructions (its soul), as Markdown.
  public func soul(profile: String) async throws -> String {
    try await http.json("GET", "/api/profiles/\(profile)/soul", timeout: 20)["content"].stringValue
  }

  /// The one standing "Bot Chat" a bot keeps, creating it the first time.
  public func botChat(profile: String) async throws -> (storedID: String, created: LiveSession?) {
    let listed = try await rpc.call(
      "session.list", ["profile": .string(profile), "title": "Bot Chat", "include_hidden": true, "limit": 5], timeout: 30)
    let rows = listed["sessions"].array ?? listed.array ?? []
    if let row = rows.first(where: { SessionSummary.baseTitle($0["title"].stringValue) == "Bot Chat" }),
      let id = row["id"].string ?? row["session_id"].string
    {
      return (id, nil)
    }
    let live = try await create(profile: profile, options: NewSessionOptions(title: "Bot Chat"))
    return (live.storedID, live)
  }

  // MARK: Cron

  public func cronJobs() async throws -> [CronJob] {
    let json = try await http.json("GET", "/api/cron/jobs", query: [("profile", "all")], timeout: 30)
    return (json.array ?? json["jobs"].array ?? []).map(CronJob.init(json:)).filter { !$0.id.isEmpty }
  }

  public func cronRuns(jobID: String, profile: String, limit: Int = 20) async throws -> [CronRun] {
    let json = try await http.json(
      "GET", "/api/cron/jobs/\(jobID)/runs", query: [("profile", profile), ("limit", String(limit))], timeout: 30)
    return (json["runs"].array ?? json.array ?? []).map(CronRun.init(json:))
  }

  public func pauseCron(jobID: String, profile: String) async throws {
    try await http.json("POST", "/api/cron/jobs/\(jobID)/pause", query: [("profile", profile)], body: [:], timeout: 30)
  }

  public func resumeCron(jobID: String, profile: String) async throws {
    try await http.json("POST", "/api/cron/jobs/\(jobID)/resume", query: [("profile", profile)], body: [:], timeout: 30)
  }

  /// Runs a job now, outside its schedule. This spends model calls for agent jobs.
  public func triggerCron(jobID: String, profile: String) async throws {
    try await http.json("POST", "/api/cron/jobs/\(jobID)/trigger", query: [("profile", profile)], body: [:], timeout: 60)
  }

  // MARK: Kanban

  public func kanbanBoards() async throws -> (boards: [KanbanBoardSummary], current: String) {
    let json = try await http.json("GET", "/api/plugins/kanban/boards", timeout: 20)
    let boards = (json["boards"].array ?? []).map(KanbanBoardSummary.init(json:)).filter { !$0.slug.isEmpty }
    return (boards, json["current"].stringValue)
  }

  public func kanbanBoard(slug: String) async throws -> KanbanBoard {
    let query = slug.isEmpty ? [] : [("board", slug)]
    return KanbanBoard(json: try await http.json("GET", "/api/plugins/kanban/board", query: query, timeout: 30))
  }

  public func kanbanTask(id: String, board: String) async throws -> KanbanTaskDetail {
    let query = board.isEmpty ? [] : [("board", board)]
    return KanbanTaskDetail(json: try await http.json("GET", "/api/plugins/kanban/tasks/\(id)", query: query, timeout: 30))
  }
}
