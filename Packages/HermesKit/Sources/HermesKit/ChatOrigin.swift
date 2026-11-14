import Foundation

/// Which app or process started a conversation. Hermes' own `source` cannot tell: the desktop app,
/// its web app and this app all create chats as `gui`. A script on the Mac backfills every chat
/// (`~/.hermes/plugin-data/chat-origins/origins.json`); rows it has not seen yet fall back to
/// what their source says.
public enum ChatOrigin: String, Sendable, CaseIterable, Hashable {
  case desktop, talaria, terminal, hermesdash, workdash, messaging, automation, test, empty, unknown

  public var label: String {
    switch self {
    case .desktop: return "Hermes app"
    case .talaria: return "Talaria"
    case .terminal: return "Terminal"
    case .hermesdash: return "hermesdash"
    case .workdash: return "Workdash"
    case .messaging: return "Slack"
    case .automation: return "Automation"
    case .test: return "Tests"
    case .empty: return "Empty"
    case .unknown: return "New"
    }
  }

  public var symbol: String {
    switch self {
    case .desktop: return "macbook"
    case .talaria: return "iphone"
    case .terminal: return "apple.terminal"
    case .hermesdash: return "safari"
    case .workdash: return "square.grid.3x3.square"
    case .messaging: return "number"
    case .automation: return "gearshape.2"
    case .test: return "testtube.2"
    case .empty: return "circle.dashed"
    case .unknown: return "sparkle"
    }
  }

  /// Started by a person typing, as opposed to tools and bots doing work on their own.
  public var isPersonal: Bool {
    switch self {
    case .desktop, .talaria, .terminal, .hermesdash, .unknown: return true
    case .workdash, .messaging, .automation, .test, .empty: return false
    }
  }
}

/// One chat's origin and how sure the backfill was.
public struct ChatOriginTag: Sendable, Hashable {
  public enum Confidence: String, Sendable { case certain, likely, guess }

  public var origin: ChatOrigin
  /// Finer kind: `cron`, `kanban`, `subagent` for automation; the platform for messaging.
  public var detail: String
  public var confidence: Confidence

  public init(origin: ChatOrigin, detail: String = "", confidence: Confidence) {
    self.origin = origin
    self.detail = detail
    self.confidence = confidence
  }

  /// What a row's own fields say when the backfill has not seen it yet.
  public static func fallback(for session: SessionSummary) -> ChatOriginTag {
    let source = session.source
    if SessionSection.messagingSources.contains(source) {
      return ChatOriginTag(origin: .messaging, detail: source, confidence: .certain)
    }
    switch source {
    case "cron", "kanban", "subagent", "tool", "oneshot", "webhook", "api_server", "acp":
      return ChatOriginTag(origin: .automation, detail: source, confidence: .certain)
    case "tui", "cli":
      return ChatOriginTag(origin: .terminal, confidence: .certain)
    default:
      break
    }
    if source == "local", session.createdSource == "cli" {
      return ChatOriginTag(origin: .workdash, confidence: .likely)
    }
    if session.createdSource == "cli" || session.createdSource == "tui" {
      return ChatOriginTag(origin: .terminal, confidence: .certain)
    }
    return ChatOriginTag(origin: .unknown, confidence: .guess)
  }
}

/// The backfill's answers by stored session id (ids are unique across profiles).
public struct ChatOriginMap: Sendable, Equatable {
  public var tags: [String: ChatOriginTag]
  public var generatedAt: String

  public static let empty = ChatOriginMap(tags: [:], generatedAt: "")
  /// Where the Mac keeps it, relative to the Mac's home.
  public static let path = "~/.hermes/plugin-data/chat-origins/origins.json"

  public init(tags: [String: ChatOriginTag], generatedAt: String) {
    self.tags = tags
    self.generatedAt = generatedAt
  }

  /// `{"generated_at": "...", "chats": {"<id>": "<origin>|<detail>|<c|l|g>"}}`. Unknown origins
  /// from a newer script are skipped so their rows fall back to the source.
  public init(json text: String) {
    guard let data = text.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let chats = root["chats"] as? [String: String]
    else {
      self = .empty
      return
    }
    var tags: [String: ChatOriginTag] = [:]
    tags.reserveCapacity(chats.count)
    for (id, packed) in chats {
      let parts = packed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard let first = parts.first else { continue }
      let name = first.contains(":") ? String(first.split(separator: ":")[0]) : first
      let origin: ChatOrigin
      if let known = ChatOrigin(rawValue: name) {
        origin = known
      } else if SessionSection.messagingSources.contains(name) {
        origin = .messaging
      } else {
        continue
      }
      let detail = parts.count > 1 ? parts[1] : (origin == .messaging ? name : "")
      let confidence: ChatOriginTag.Confidence
      switch parts.count > 2 ? parts[2] : "g" {
      case "c": confidence = .certain
      case "l": confidence = .likely
      default: confidence = .guess
      }
      tags[id] = ChatOriginTag(origin: origin, detail: detail.isEmpty && origin == .messaging ? name : detail,
                               confidence: confidence)
    }
    self.init(tags: tags, generatedAt: root["generated_at"] as? String ?? "")
  }

  /// The tag for a row: chats this phone started win, then the backfill, then the row's source.
  public func tag(for session: SessionSummary, startedHere: Set<String> = []) -> ChatOriginTag {
    if startedHere.contains(session.id) { return ChatOriginTag(origin: .talaria, confidence: .certain) }
    if let tag = tags[session.id] { return tag }
    // A version made by continuing a chat carries its parent's origin until the backfill sees it.
    if let parent = session.parentID, let tag = tags[parent] { return tag }
    return .fallback(for: session)
  }
}

/// What the inbox shows.
public enum ChatOriginFilter: Hashable, Sendable {
  case all
  /// Chats a person started (Hermes app, Talaria, terminal, hermesdash, not yet tagged).
  case personal
  case only(ChatOrigin)

  public init(storage: String) {
    switch storage {
    case "", "all": self = .all
    case "personal": self = .personal
    default: self = ChatOrigin(rawValue: storage).map { .only($0) } ?? .all
    }
  }

  public var storage: String {
    switch self {
    case .all: return "all"
    case .personal: return "personal"
    case .only(let origin): return origin.rawValue
    }
  }

  public var label: String {
    switch self {
    case .all: return "All chats"
    case .personal: return "Started by me"
    case .only(let origin): return origin.label
    }
  }

  public var symbol: String {
    switch self {
    case .all: return "tray.full"
    case .personal: return "person"
    case .only(let origin): return origin.symbol
    }
  }

  public func includes(_ origin: ChatOrigin) -> Bool {
    switch self {
    case .all: return true
    case .personal: return origin.isPersonal
    case .only(let wanted): return origin == wanted
    }
  }

  /// The choices in the menu, in order.
  public static let menu: [ChatOriginFilter] = [.all, .personal] + [
    ChatOrigin.desktop, .talaria, .terminal, .workdash, .messaging, .automation, .test, .hermesdash, .unknown,
  ].map { .only($0) }
}

extension HermesClient {
  /// The Mac's backfilled origins, read through Hermes' file preview (no extra route on the Mac).
  /// Empty when the file is missing or cut short.
  public func chatOrigins() async throws -> ChatOriginMap {
    let preview = try await filePreview(path: ChatOriginMap.path, profile: "default", storedID: nil)
    guard !preview.isTruncated else { return .empty }
    return ChatOriginMap(json: preview.text)
  }
}
