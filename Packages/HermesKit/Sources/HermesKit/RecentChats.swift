import Foundation

/// The chats opened most recently on this phone, newest first: the app icon's quick actions.
/// Kept on the phone only (`UserDefaults`), never sent anywhere.
public struct RecentChats: Codable, Sendable, Equatable {
  public struct Entry: Codable, Sendable, Equatable {
    public var profile: String
    public var storedID: String
    /// The chat's title when it was last seen; empty for a chat with none yet.
    public var title: String
    /// The bot's name, shown under the title.
    public var botTitle: String

    public init(profile: String, storedID: String, title: String, botTitle: String) {
      self.profile = profile
      self.storedID = storedID
      self.title = title
      self.botTitle = botTitle
    }

    public var displayTitle: String { title.isEmpty ? "Untitled chat" : title }
  }

  public static let limit = 3

  public private(set) var entries: [Entry]

  public init(entries: [Entry] = []) {
    self.entries = Array(entries.prefix(Self.limit))
  }

  /// A chat was opened: it moves to the front. An empty title keeps the one already known.
  public func opened(profile: String, storedID: String, title: String, botTitle: String) -> RecentChats {
    let known = entries.first { $0.storedID == storedID }
    let entry = Entry(
      profile: profile, storedID: storedID, title: title.isEmpty ? known?.title ?? "" : title,
      botTitle: botTitle.isEmpty ? known?.botTitle ?? "" : botTitle)
    return RecentChats(entries: [entry] + entries.filter { $0.storedID != storedID })
  }

  public func removing(_ storedID: String) -> RecentChats {
    RecentChats(entries: entries.filter { $0.storedID != storedID })
  }

  /// Takes the titles from a fresh list read. A chat the list shows as archived drops out. One the
  /// list leaves out keeps what was known (the list is a window, not every chat), unless the read
  /// holds all of its bot's chats (`totals`, the Mac's count per bot): then it was archived or
  /// deleted on the Mac.
  public func refreshingTitles(
    from rows: [SessionSummary], botTitles: [String: String] = [:], totals: [String: Int] = [:]
  ) -> RecentChats {
    var byID: [String: SessionSummary] = [:]
    var listed: [String: Int] = [:]
    for row in rows {
      byID[row.id] = row
      listed[row.profile, default: 0] += 1
    }
    var out: [Entry] = []
    for var entry in entries {
      if let row = byID[entry.storedID] {
        if row.archived { continue }
        entry.title = row.baseTitle
      } else if let total = totals[entry.profile], listed[entry.profile, default: 0] >= total {
        continue
      }
      if let bot = botTitles[entry.profile], !bot.isEmpty { entry.botTitle = bot }
      out.append(entry)
    }
    return RecentChats(entries: out)
  }

  /// What the app icon offers: a new chat with `newChat`'s bot, then the recent chats.
  public func quickActions(newChat: (profile: String, botTitle: String)?) -> [QuickActionItem] {
    var items: [QuickActionItem] = []
    if let newChat {
      items.append(
        QuickActionItem(
          action: .newChat(profile: newChat.profile), title: "New chat", subtitle: newChat.botTitle,
          symbol: "square.and.pencil"))
    }
    for entry in entries {
      items.append(
        QuickActionItem(
          action: .chat(profile: entry.profile, storedID: entry.storedID), title: entry.displayTitle,
          subtitle: entry.botTitle, symbol: "bubble.left"))
    }
    return items
  }
}

/// One of the app icon's quick actions, as the icon carries it (`type` and `userInfo`).
public enum QuickAction: Equatable, Sendable {
  case newChat(profile: String)
  case chat(profile: String, storedID: String)

  /// `<bundle id>.newchat` or `<bundle id>.chat`.
  public func type(bundleID: String) -> String {
    switch self {
    case .newChat: "\(bundleID).newchat"
    case .chat: "\(bundleID).chat"
    }
  }

  public var userInfo: [String: String] {
    switch self {
    case .newChat(let profile): ["profile": profile]
    case .chat(let profile, let storedID): ["profile": profile, "storedID": storedID]
    }
  }

  public init?(type: String, userInfo: [String: Any]?) {
    let profile = userInfo?["profile"] as? String ?? ""
    if type.hasSuffix(".newchat") {
      guard !profile.isEmpty else { return nil }
      self = .newChat(profile: profile)
    } else if type.hasSuffix(".chat") {
      guard let storedID = userInfo?["storedID"] as? String, !storedID.isEmpty else { return nil }
      self = .chat(profile: profile.isEmpty ? "default" : profile, storedID: storedID)
    } else {
      return nil
    }
  }
}

public struct QuickActionItem: Equatable, Sendable {
  public var action: QuickAction
  public var title: String
  public var subtitle: String
  /// An SF Symbol name.
  public var symbol: String
}
