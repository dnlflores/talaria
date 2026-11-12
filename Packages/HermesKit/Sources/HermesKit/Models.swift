import Foundation

/// One row of the sidebar: a stored conversation in some profile.
public struct SessionSummary: Identifiable, Sendable, Hashable {
  public let id: String
  public var profile: String
  public var title: String
  public var preview: String
  public var source: String
  /// The surface that first created the conversation (`desktop`, `cli`, ...), which `source` loses once it is resumed elsewhere.
  public var createdSource: String
  public var model: String
  public var provider: String
  public var cwd: String
  public var gitBranch: String
  public var startedAt: Double
  public var lastActive: Double
  public var isActive: Bool
  public var unread: Bool
  public var pinned: Bool
  public var archived: Bool
  public var parentID: String?
  public var messageCount: Int
  /// What the agent was doing at `lastActivityAt` during a turn ("executing tool terminal").
  /// Hermes clears it when the turn ends, so it is empty between turns.
  public var lastActivity: String
  /// The agent's heartbeat in the shared session store, written by whichever Hermes process runs
  /// the turn, at least once a minute while it runs.
  public var lastActivityAt: Double
  public var chatID: String
  public var chatType: String
  public var displayName: String
  public var originJSON: String
  /// Fence for metadata writes: the backend rejects a write that names a stale revision.
  public var revision: Int

  public init(json: JSONValue) {
    id = json["id"].stringValue
    profile = json["profile"].string ?? json["profile_name"].string ?? "default"
    title = json["title"].stringValue
    preview = json["preview"].stringValue
    source = json["source"].stringValue.lowercased()
    createdSource = (json["created_source"].string ?? json["source"].stringValue).lowercased()
    model = json["model"].stringValue
    provider = json["billing_provider"].stringValue
    cwd = json["cwd"].stringValue
    gitBranch = json["git_branch"].stringValue
    startedAt = json["started_at"].double ?? 0
    lastActive = json["last_active"].double ?? json["last_activity_at"].double ?? 0
    isActive = json["is_active"].truthy
    unread = json["unread"].truthy
    pinned = json["pinned"].truthy
    archived = json["archived"].truthy
    parentID = json["parent_session_id"].string
    messageCount = json["message_count"].int ?? 0
    lastActivity = json["last_activity_description"].stringValue
    lastActivityAt = json["last_activity_at"].double ?? 0
    chatID = json["chat_id"].stringValue
    chatType = json["chat_type"].stringValue
    displayName = json["display_name"].stringValue
    originJSON = json["origin_json"].stringValue
    revision = json["runtime_revision"].int ?? 0
  }

  /// Most recent sign of life, for ordering.
  public var recency: Double { lastActive > 0 ? lastActive : startedAt }

  /// How long a heartbeat counts. Hermes stamps a running turn at least every 60 seconds; a
  /// process that died mid-turn never clears its label, so an old stamp means nothing is running.
  public static let heartbeatWindow: Double = 180

  /// A turn is running in this chat in some Hermes process, maybe one this app cannot talk to
  /// (the desktop app runs its own backend). Read from the shared session store.
  public func isTurnRunning(now: Double) -> Bool {
    guard !lastActivity.isEmpty, lastActivityAt > 0 else { return false }
    let age = now - lastActivityAt
    return age < SessionSummary.heartbeatWindow && age > -60
  }

  /// Title without the ` #N` suffix the backend gives a branched version.
  public var baseTitle: String { SessionSummary.baseTitle(title) }

  public static func baseTitle(_ title: String) -> String {
    title.replacing(/\s+#\d+$/, with: "")
  }

  public func matches(_ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    if needle.isEmpty { return true }
    return [title, preview, lastActivity, cwd, displayName, model, profile]
      .contains { $0.lowercased().contains(needle) }
  }
}

/// A Hermes profile: its own config, memory, skills and default model. The desktop app calls these bots.
public struct Profile: Identifiable, Sendable, Hashable {
  public var id: String { name }
  public let name: String
  public var displayName: String
  public var botTitle: String
  public var model: String
  public var provider: String
  public var summary: String
  public var isDefault: Bool
  public var hasAvatar: Bool
  public var skillCount: Int

  public init(json: JSONValue) {
    name = json["name"].stringValue
    displayName = json["display_name"].stringValue
    botTitle = json["ui_meta"]["hermes-bots"]["title"].stringValue
    model = json["model"].stringValue
    provider = json["provider"].stringValue
    summary = json["description"].stringValue
    isDefault = json["is_default"].truthy
    hasAvatar = json["has_avatar"].truthy
    skillCount = json["skill_count"].int ?? 0
  }

  /// The name to show: the bot title, else the display name, else the profile name.
  public var title: String {
    if !botTitle.isEmpty { return botTitle }
    if !displayName.isEmpty { return displayName }
    return name == "default" ? "Hermes" : name
  }
}

/// What the backend reports about a live session; fields merge as events arrive.
public struct SessionInfo: Sendable, Equatable {
  public var model = ""
  public var provider = ""
  public var reasoningEffort = ""
  public var cwd = ""
  public var branch = ""
  public var approvalMode = ""
  public var title = ""
  public var isRunning = false

  public init() {}

  /// Copies the fields that are present and non-empty, leaving the rest alone.
  public mutating func merge(_ json: JSONValue) {
    func take(_ key: String, into target: inout String) {
      if let value = json[key].string, !value.isEmpty { target = value }
    }
    take("model", into: &model)
    take("provider", into: &provider)
    take("reasoning_effort", into: &reasoningEffort)
    take("cwd", into: &cwd)
    take("branch", into: &branch)
    take("approval_mode", into: &approvalMode)
    take("title", into: &title)
    if let running = json["running"].bool { isRunning = running }
  }
}

public struct ModelProvider: Identifiable, Sendable, Hashable {
  public struct Model: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let supportsReasoning: Bool
    public let supportsFast: Bool
  }

  public var id: String { slug }
  public let slug: String
  public let name: String
  public let isCurrent: Bool
  public let isAuthenticated: Bool
  public let models: [Model]
  /// Models listed that this plan does not include (a free tier lists the rest of the catalog).
  public let unavailable: Set<String>
  /// The backend has not checked this plan yet and locks every model meanwhile.
  public let isCheckingPlan: Bool
  /// The backend's note about this provider ("Checking Nous plan entitlement…").
  public let warning: String

  public init(json: JSONValue) {
    slug = json["slug"].stringValue
    name = json["name"].string ?? slug
    isCurrent = json["is_current"].truthy
    isAuthenticated = json["authenticated"].truthy
    let locked = Set((json["unavailable_models"].array ?? []).compactMap(\.string))
    unavailable = locked
    warning = json["warning"].stringValue
    let listed = (json["models"].array ?? []).compactMap(\.string)
    isCheckingPlan = json["free_tier_pending"].truthy
      || (json["pricing_pending"].truthy && !listed.isEmpty && listed.allSatisfy { locked.contains($0) })
    let capabilities = json["capabilities"].object ?? [:]
    var seen = Set<String>()
    var ordered: [String] = []
    for name in (json["models"].array ?? []).compactMap(\.string) + capabilities.keys.sorted() where seen.insert(name).inserted {
      ordered.append(name)
    }
    models = ordered.map { name in
      Model(name: name, supportsReasoning: capabilities[name]?["reasoning"].truthy ?? false,
            supportsFast: capabilities[name]?["fast"].truthy ?? false)
    }
  }

  /// Providers in picker order: the current one, then signed-in ones, then by name.
  public static func catalog(from json: JSONValue) -> [ModelProvider] {
    (json["providers"].array ?? []).map(ModelProvider.init(json:)).sorted { a, b in
      if a.isCurrent != b.isCurrent { return a.isCurrent }
      if a.isAuthenticated != b.isAuthenticated { return a.isAuthenticated }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }
}

/// Another Hermes process on the Mac that has a chat open. The backend allows one live owner per chat.
public struct ChatOwner: Sendable, Hashable {
  public let sessionID: String
  public let surface: String

  public init(sessionID: String, surface: String) {
    self.sessionID = sessionID
    self.surface = surface
  }

  public init(json: JSONValue) {
    sessionID = json["session_id"].stringValue
    surface = json["surface"].stringValue
  }

  public var place: String {
    switch surface {
    case "desktop": return "the Hermes app on your Mac"
    case "cli", "tui": return "a terminal on your Mac"
    case "gateway": return "the messaging gateway"
    default: return SessionSection.messagingSources.contains(surface) ? "the messaging gateway" : "another Hermes window on your Mac"
    }
  }
}

public let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
