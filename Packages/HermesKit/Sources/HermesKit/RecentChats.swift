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
    /// False for a chat made here that nothing was sent in yet: the Mac has no such chat to open,
    /// so the icon leaves it out. It still holds its place in the opening order until it is saved.
    public var saved: Bool

    public init(profile: String, storedID: String, title: String, botTitle: String, saved: Bool = true) {
      self.profile = profile
      self.storedID = storedID
      self.title = title
      self.botTitle = botTitle
      self.saved = saved
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profile = try container.decode(String.self, forKey: .profile)
      storedID = try container.decode(String.self, forKey: .storedID)
      title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
      botTitle = try container.decodeIfPresent(String.self, forKey: .botTitle) ?? ""
      saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? true
    }

    public var displayTitle: String { title.isEmpty ? "Untitled chat" : title }
  }

  /// What a single-chat read said about a saved chat the inbox list left out.
  public enum Lookup: Sendable, Hashable {
    /// The Mac has it: a valid older chat (kept) or an archived one (dropped).
    case found(SessionSummary)
    /// The Mac has no such chat (deleted there).
    case gone
    /// The read failed some other way (offline, timeout, sign-in): keep what is known.
    case unknown

    public init(_ result: Result<SessionSummary, any Error>) {
      switch result {
      case .success(let row):
        self = .found(row)
      case .failure(let error):
        if case HermesError.http(status: 404, _)? = error as? HermesError {
          self = .gone
        } else {
          self = .unknown
        }
      }
    }
  }

  public static let limit = 3

  public private(set) var entries: [Entry]

  public init(entries: [Entry] = []) {
    self.entries = Self.trimmed(entries)
  }

  /// Keeps entries up to the third saved one. Unsaved entries ahead of it keep their place (at most
  /// `limit` of them), so a chat made here and saved later lands where it was opened.
  private static func trimmed(_ entries: [Entry]) -> [Entry] {
    var out: [Entry] = []
    var saved = 0
    var unsaved = 0
    for entry in entries where saved < limit {
      if entry.saved {
        saved += 1
      } else {
        guard unsaved < limit else { continue }
        unsaved += 1
      }
      out.append(entry)
    }
    return out
  }

  /// The chats the icon offers, newest first.
  public var shown: [Entry] { entries.filter(\.saved) }

  /// A chat was opened: it moves to the front. An empty title keeps the one already known, and a
  /// chat already saved stays saved.
  public func opened(
    profile: String, storedID: String, title: String, botTitle: String, saved: Bool = true
  ) -> RecentChats {
    let known = entries.first { $0.storedID == storedID }
    let entry = Entry(
      profile: profile, storedID: storedID, title: title.isEmpty ? known?.title ?? "" : title,
      botTitle: botTitle.isEmpty ? known?.botTitle ?? "" : botTitle, saved: saved || known?.saved == true)
    return RecentChats(entries: [entry] + entries.filter { $0.storedID != storedID })
  }

  /// A message from this phone reached the Mac: the chat is saved there now. It keeps its place in
  /// the opening order (a send can finish after other chats were opened), and one no longer in the
  /// list (archived here, or pushed out by newer chats) stays out.
  public func saving(_ storedID: String, title: String) -> RecentChats {
    var out = entries
    guard let index = out.firstIndex(where: { $0.storedID == storedID }) else { return self }
    out[index].saved = true
    if !title.isEmpty { out[index].title = title }
    return RecentChats(entries: out)
  }

  public func removing(_ storedID: String) -> RecentChats {
    RecentChats(entries: entries.filter { $0.storedID != storedID })
  }

  /// Takes the titles from a fresh list read. A chat the list shows as archived drops out. One the
  /// list leaves out keeps what was known: the list is a window, so `unlisted(in:)` names those for
  /// a single-chat read each (`reconciling`).
  public func refreshingTitles(from rows: [SessionSummary], botTitles: [String: String] = [:]) -> RecentChats {
    var byID: [String: SessionSummary] = [:]
    for row in rows { byID[row.id] = row }
    var out: [Entry] = []
    for var entry in entries {
      if let row = byID[entry.storedID] {
        if row.archived { continue }
        entry.title = row.baseTitle
        entry.saved = true
      }
      if let bot = botTitles[entry.profile], !bot.isEmpty { entry.botTitle = bot }
      out.append(entry)
    }
    return RecentChats(entries: out)
  }

  /// Saved chats a list read left out, to be read one by one: at most `limit`.
  public func unlisted(in rows: [SessionSummary]) -> [Entry] {
    let listed = Set(rows.map(\.id))
    return shown.filter { !listed.contains($0.storedID) }
  }

  /// Reads each entry with `read` (the Mac's single-chat read), all at once.
  public static func lookUp(
    _ entries: [Entry], read: @escaping @Sendable (Entry) async throws -> SessionSummary
  ) async -> [String: Lookup] {
    await withTaskGroup(of: (String, Lookup).self) { group in
      for entry in entries {
        group.addTask {
          do {
            return (entry.storedID, Lookup(.success(try await read(entry))))
          } catch {
            return (entry.storedID, Lookup(.failure(error)))
          }
        }
      }
      var out: [String: Lookup] = [:]
      for await (id, lookup) in group { out[id] = lookup }
      return out
    }
  }

  /// Applies single-chat reads: archived or deleted chats drop out, others take the fresh title, and
  /// a failed read changes nothing. Entries removed meanwhile stay removed.
  public func reconciling(_ lookups: [String: Lookup]) -> RecentChats {
    var out: [Entry] = []
    for var entry in entries {
      switch lookups[entry.storedID] {
      case .gone:
        continue
      case .found(let row):
        if row.archived { continue }
        entry.title = row.baseTitle
      case .unknown, nil:
        break
      }
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
    for entry in shown {
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
