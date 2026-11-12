import Foundation
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
  private var drafts: [String: String]

  private enum Key {
    /// Hermes' own listener. Its own key: an address saved for the hermesdash gate (the old
    /// `server.address`) must not carry over, or the app would keep going through hermesdash.
    static let server = "hermes.address"
    static let theme = "theme.family"
    static let appearance = "theme.appearance"
    static let lastProfile = "chat.lastProfile"
    static let profileFilter = "home.profileFilter"
    static let drafts = "chat.drafts"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    serverAddress = defaults.string(forKey: Key.server) ?? ""
    themeFamily = ThemeFamily(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .standard
    appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    lastProfile = defaults.string(forKey: Key.lastProfile) ?? ""
    profileFilter = defaults.string(forKey: Key.profileFilter) ?? ""
    drafts = defaults.dictionary(forKey: Key.drafts) as? [String: String] ?? [:]
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
}
