import Foundation

public enum BackgroundWorkStatus: String, Sendable {
  case queued, running, completed, failed, stopped, finished, unknown

  public var isRunning: Bool { self == .running || self == .queued }
  public var label: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .completed: "Completed"
    case .failed: "Failed"
    case .stopped: "Stopped"
    case .finished: "No longer running"
    case .unknown: "Status unknown"
    }
  }
}

public struct BackgroundWorkItem: Identifiable, Sendable, Equatable {
  public enum Kind: Sendable { case agent, process }
  public let id: String
  public let kind: Kind
  public let title: String
  public let detail: String
  public var status: BackgroundWorkStatus
  public let startedAt: Double
  public let exitCode: Int?
}

public enum BackgroundWorkError: Error { case invalidResponse, missingScope }

public struct BackgroundWorkScope: Sendable, Hashable {
  public let profile: String
  public let storedID: String
  public init(profile: String, storedID: String) {
    self.profile = profile
    self.storedID = storedID
  }
}

extension BackgroundWorkSnapshot {
  public static func load(
    scope: BackgroundWorkScope,
    request: @Sendable (String, JSONValue) async throws -> JSONValue
  ) async throws -> BackgroundWorkSnapshot {
    guard !scope.profile.isEmpty, !scope.storedID.isEmpty else { throw BackgroundWorkError.missingScope }
    let params: JSONValue = ["session_id": .string(scope.storedID), "profile": .string(scope.profile)]
    async let subagents = request("subagent.list", params)
    async let processes = request("process.list", params)
    return try await BackgroundWorkSnapshot(subagents: subagents, processes: processes)
  }
}

extension HermesClient {
  public func backgroundWork(profile: String, storedID: String) async throws -> BackgroundWorkSnapshot {
    try await BackgroundWorkSnapshot.load(scope: BackgroundWorkScope(profile: profile, storedID: storedID)) { method, params in
      try await self.rpc.call(method, params, timeout: 10)
    }
  }
}

/// Two authoritative, session-scoped gateway reads. No attachment or resume is required.
public struct BackgroundWorkSnapshot: Sendable {
  public let rows: [BackgroundWorkItem]

  public init(subagents: JSONValue, processes: JSONValue) throws {
    guard let agents = subagents["subagents"].array,
          let commands = processes["processes"].array else { throw BackgroundWorkError.invalidResponse }
    rows = agents.compactMap { row in
      guard let id = row["subagent_id"].string, !id.isEmpty else { return nil }
      let goal = row["goal"].stringValue
      return BackgroundWorkItem(id: "agent:\(id)", kind: .agent,
        title: goal.isEmpty ? "Background agent" : goal, detail: goal,
        status: Self.agentStatus(row["status"].stringValue), startedAt: row["started_at"].double ?? 0, exitCode: nil)
    } + (subagents["delegations"].array ?? []).compactMap { row in
      guard let id = row["delegation_id"].string, !id.isEmpty else { return nil }
      let goal = row["goal"].stringValue
      let error = row["error"].stringValue
      return BackgroundWorkItem(id: "delegation:\(id):\(row["task_index"].int ?? 0)", kind: .agent,
        title: goal.isEmpty ? "Background agent" : goal,
        detail: [goal, error].filter { !$0.isEmpty }.joined(separator: "\n\n"),
        status: Self.agentStatus(row["status"].stringValue),
        startedAt: row["dispatched_at"].double ?? 0, exitCode: nil)
    } + commands.compactMap { row in
      guard let id = row["session_id"].string, !id.isEmpty else { return nil }
      return BackgroundWorkItem(id: "process:\(id)", kind: .process,
        title: "Background command", detail: row["command"].stringValue,
        status: Self.processStatus(row), startedAt: row["started_epoch"].double ?? 0, exitCode: row["exit_code"].int)
    }
  }

  private static func agentStatus(_ value: String) -> BackgroundWorkStatus {
    switch value {
    case "running": .running
    case "queued": .queued
    case "completed": .completed
    case "failed", "error", "timeout": .failed
    case "interrupted", "cancelled", "canceled", "stopped": .stopped
    default: .unknown
    }
  }

  private static func processStatus(_ row: JSONValue) -> BackgroundWorkStatus {
    let status = row["status"].stringValue
    let reason = row["completion_reason"].stringValue
    if ["killed", "cancelled", "canceled", "stopped"].contains(status)
      || ["killed", "cancelled", "canceled", "stopped"].contains(reason) { return .stopped }
    if status == "running" { return .running }
    if reason == "lost" { return .unknown }
    if reason == "failed_start" { return .failed }
    guard status == "exited" else { return .unknown }
    guard let code = row["exit_code"].int else { return .finished }
    return code == 0 ? .completed : .failed
  }
}

/// Independent of the foreground reply's streaming state.
public struct BackgroundWorkState: Sendable {
  public private(set) var rows: [BackgroundWorkItem] = []
  public private(set) var isUnavailable = false
  public private(set) var hasSnapshot = false
  public var runningCount: Int { rows.filter { $0.status.isRunning }.count }
  public var summary: String { "Background work · \(runningCount) running" }

  public init() {}
  public mutating func markUnavailable() { isUnavailable = true }

  public mutating func apply(_ snapshot: BackgroundWorkSnapshot) {
    isUnavailable = false
    hasSnapshot = true
    var merged = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let present = Set(snapshot.rows.map(\.id))
    for (id, var row) in merged where !present.contains(id) && row.status.isRunning {
      // A live registry pruning a child is not proof of success or failure.
      row.status = .finished
      merged[id] = row
    }
    for row in snapshot.rows { merged[row.id] = row }
    let ordered = merged.values.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
      return $0.id < $1.id
    }
    rows = ordered.filter { $0.status.isRunning } + ordered.filter { !$0.status.isRunning }.prefix(20)
  }
}
