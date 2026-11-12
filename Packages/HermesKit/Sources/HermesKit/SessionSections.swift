import Foundation

/// Where a conversation came from. Every conversation lives in exactly one section,
/// decided by its source, the same way the desktop app sorts them.
public enum SessionSection: Sendable, Hashable {
  /// Conversations a person started: desktop app, terminal, this app.
  case chats
  /// Threads a bot answered on a messaging platform (`slack`, `telegram`, ...).
  case platform(String)
  /// Requests through the API server or a webhook.
  case api
  /// Work bots did on their own: kanban tasks, cron jobs, one-shot runs, sub-agents.
  case runs

  static let chatSources: Set<String> = ["desktop", "cli", "tui", "local", "codex", "gateway", ""]
  static let apiSources: Set<String> = ["api_server", "webhook"]
  public static let messagingSources: [String] = [
    "slack", "telegram", "discord", "whatsapp", "signal", "bluebubbles", "photon", "matrix", "mattermost",
    "email", "sms", "homeassistant", "weixin", "wecom", "qqbot", "yuanbao", "dingtalk", "feishu",
  ]

  public init(source: String) {
    let source = source.lowercased()
    if Self.apiSources.contains(source) {
      self = .api
    } else if Self.messagingSources.contains(source) {
      self = .platform(source)
    } else if Self.chatSources.contains(source) {
      self = .chats
    } else {
      self = .runs
    }
  }

  /// Channels are answered by the gateway, not by this app, so they open read-only.
  public var isChannel: Bool {
    switch self {
    case .platform, .api: return true
    case .chats, .runs: return false
    }
  }

  public var label: String {
    switch self {
    case .chats: return "Chats"
    case .runs: return "Runs"
    case .api: return "API"
    case .platform(let source): return SessionSection.sourceLabel(source)
    }
  }

  private static let sourceLabels: [String: String] = [
    "desktop": "App", "cli": "Terminal", "tui": "Terminal", "local": "Local", "codex": "Codex", "gateway": "Gateway",
    "api_server": "API", "webhook": "Webhook", "oneshot": "One-shot run", "kanban": "Kanban task",
    "cron": "Scheduled job", "acp": "Editor", "subagent": "Sub-agent", "slack": "Slack", "telegram": "Telegram",
    "discord": "Discord", "whatsapp": "WhatsApp", "bluebubbles": "iMessage", "photon": "iMessage",
    "signal": "Signal", "email": "Email", "sms": "SMS", "matrix": "Matrix", "mattermost": "Mattermost",
    "homeassistant": "Home Assistant",
  ]

  public static func sourceLabel(_ source: String) -> String {
    if let known = sourceLabels[source] { return known }
    if source.isEmpty { return "Other" }
    return source.replacing(/[_-]+/, with: " ").capitalized
  }
}

extension SessionSummary {
  public var section: SessionSection { SessionSection(source: source) }
}

/// Versions of one conversation. Continuing a chat that another process holds branches it:
/// the copy has `parent_session_id` and the title `<original> #N`. Lists show one row per family.
public struct SessionFamily: Sendable, Hashable {
  public let rootID: String
  /// Oldest first.
  public let members: [SessionSummary]

  /// The version a list row stands for: the most recently active one.
  public var preferred: SessionSummary {
    members.max { $0.recency < $1.recency } ?? members[0]
  }
}

public enum SessionGrouping {
  /// Families with two or more members, keyed by every member's id.
  public static func families(_ sessions: [SessionSummary]) -> [String: SessionFamily] {
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func root(of session: SessionSummary) -> SessionSummary {
      var current = session
      var hops = 0
      while let parentID = current.parentID, hops < 25, let parent = byID[parentID],
        parent.profile == session.profile, parent.section == session.section
      {
        current = parent
        hops += 1
      }
      return current
    }
    var groups: [String: [SessionSummary]] = [:]
    for session in sessions { groups[root(of: session).id, default: []].append(session) }
    var out: [String: SessionFamily] = [:]
    for (rootID, members) in groups where members.count > 1 {
      let family = SessionFamily(rootID: rootID, members: members.sorted { $0.startedAt < $1.startedAt })
      for member in members { out[member.id] = family }
    }
    return out
  }

  /// One row per family (its preferred member), keeping the incoming order.
  public static func collapse(_ rows: [SessionSummary], families: [String: SessionFamily]) -> [SessionSummary] {
    guard !families.isEmpty else { return rows }
    var chosen: [String: String] = [:]
    for row in rows {
      guard let family = families[row.id], chosen[family.rootID] == nil else { continue }
      let present = rows.filter { families[$0.id]?.rootID == family.rootID }
      chosen[family.rootID] = (present.max { $0.recency < $1.recency } ?? row).id
    }
    return rows.filter { row in
      guard let family = families[row.id] else { return true }
      return chosen[family.rootID] == row.id
    }
  }

  /// Sidebar order: pinned first, then newest activity.
  public static func sorted(_ sessions: [SessionSummary]) -> [SessionSummary] {
    sessions.sorted { a, b in
      if a.pinned != b.pinned { return a.pinned }
      return a.recency > b.recency
    }
  }

  /// Merges the sidebar slices into one de-duplicated, ordered list.
  public static func rows(fromSidebar json: JSONValue) -> [SessionSummary] {
    var seen = Set<String>()
    var rows: [SessionSummary] = []
    for slice in ["recents", "messaging", "cron"] {
      for item in json[slice]["sessions"].array ?? [] {
        let row = SessionSummary(json: item)
        if !row.id.isEmpty, seen.insert(row.id).inserted { rows.append(row) }
      }
    }
    return sorted(rows)
  }
}
