import Foundation
import HermesKit
import Observation

/// Settings kept on the phone. Nothing here is a credential: the session cookie lives in the Keychain.
@MainActor @Observable
final class Preferences {
  private let defaults: UserDefaults

  var serverAddress: String { didSet { defaults.set(serverAddress, forKey: Key.server) } }
  var themeFamily: ThemeFamily { didSet { defaults.set(themeFamily.rawValue, forKey: Key.theme) } }
  var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
  /// Profile the next new chat starts in.
  var lastProfile: String { didSet { defaults.set(lastProfile, forKey: Key.lastProfile) } }
  /// Home list filter: a profile name, or empty for every bot.
  var profileFilter: String { didSet { defaults.set(profileFilter, forKey: Key.profileFilter) } }
  /// A notification when a reply finishes or a bot asks something (sent by the Mac).
  var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: Key.notifyFinished) } }
  /// A Live Activity while a reply runs.
  var liveActivities: Bool { didSet { defaults.set(liveActivities, forKey: Key.liveActivities) } }
  /// Which chats notify: `all`, or `phone` (chats this phone sent to). See `PushRegistration.Scope`.
  var notifyScope: String { didSet { defaults.set(notifyScope, forKey: Key.notifyScope) } }
  /// The chats opened last on this phone, for the app icon's quick actions.
  var recentChats: RecentChats {
    didSet {
      guard recentChats != oldValue else { return }
      defaults.set(try? JSONEncoder().encode(recentChats), forKey: Key.recentChats)
    }
  }
  private var drafts: [String: String]
  /// Queued messages a closed chat had not sent, by stored id, so they outlast the app.
  private var queued: [String: [String]]

  private enum Key {
    /// Hermes' own listener. Its own key: an address saved for the hermesdash gate (the old
    /// `server.address`) must not carry over, or the app would keep going through hermesdash.
    static let server = "hermes.address"
    static let theme = "theme.family"
    /// Set once the Hermes look has been switched on for an install that predates it.
    static let hermesLook = "theme.hermesLook"
    static let appearance = "theme.appearance"
    static let lastProfile = "chat.lastProfile"
    static let profileFilter = "home.profileFilter"
    static let drafts = "chat.drafts"
    static let queued = "chat.queued"
    static let notifyFinished = "push.notifyFinished"
    static let liveActivities = "push.liveActivities"
    static let notifyScope = "push.scope"
    static let recentChats = "chat.recent"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    serverAddress = defaults.string(forKey: Key.server) ?? ""
    // The Hermes look replaced the T3 one as the app's look: switch it on once, even for a family
    // picked before it existed. Settings > Appearance still offers the others.
    if defaults.bool(forKey: Key.hermesLook) {
      themeFamily = ThemeFamily(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .hermes
    } else {
      themeFamily = .hermes
      defaults.set(ThemeFamily.hermes.rawValue, forKey: Key.theme)
      defaults.set(true, forKey: Key.hermesLook)
    }
    appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    lastProfile = defaults.string(forKey: Key.lastProfile) ?? ""
    profileFilter = defaults.string(forKey: Key.profileFilter) ?? ""
    drafts = defaults.dictionary(forKey: Key.drafts) as? [String: String] ?? [:]
    queued = defaults.dictionary(forKey: Key.queued) as? [String: [String]] ?? [:]
    notifyFinished = defaults.object(forKey: Key.notifyFinished) as? Bool ?? true
    liveActivities = defaults.object(forKey: Key.liveActivities) as? Bool ?? true
    notifyScope = defaults.string(forKey: Key.notifyScope) ?? "all"
    recentChats = defaults.data(forKey: Key.recentChats).flatMap { try? JSONDecoder().decode(RecentChats.self, from: $0) }
      ?? RecentChats()
  }

  /// The address baked in at build time from the untracked `Config/Local.xcconfig`, if any.
  static var bundledServerAddress: String {
    (Bundle.main.object(forInfoDictionaryKey: "TalariaDefaultServer") as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func draft(for storedID: String) -> String { drafts[storedID] ?? "" }

  func setDraft(_ text: String, for storedID: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      guard drafts[storedID] != nil else { return }
      drafts[storedID] = nil
    } else {
      guard drafts[storedID] != text else { return }
      drafts[storedID] = text
    }
    defaults.set(drafts, forKey: Key.drafts)
  }

  func hasDraft(for storedID: String) -> Bool { drafts[storedID] != nil }

  func queued(for storedID: String) -> [String] { queued[storedID] ?? [] }

  func setQueued(_ texts: [String], for storedID: String) {
    let next = texts.isEmpty ? nil : texts
    guard queued[storedID] != next else { return }
    queued[storedID] = next
    defaults.set(queued, forKey: Key.queued)
  }
}
