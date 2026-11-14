import HermesKit
import UIKit

/// Takes the app icon's quick actions: at launch (`connectionOptions.shortcutItem`) and while the
/// app is running in the background (`performActionFor`). SwiftUI keeps drawing the window.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let item = connectionOptions.shortcutItem else { return }
    Self.perform(item)
  }

  func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(Self.perform(shortcutItem))
  }

  @discardableResult
  private static func perform(_ item: UIApplicationShortcutItem) -> Bool {
    guard let action = QuickAction(type: item.type, userInfo: item.userInfo) else { return false }
    PushCenter.shared.perform(action)
    return true
  }
}

extension QuickActionItem {
  var shortcutItem: UIApplicationShortcutItem {
    UIApplicationShortcutItem(
      type: action.type(bundleID: Bundle.main.bundleIdentifier ?? "talaria"), localizedTitle: title,
      localizedSubtitle: subtitle.isEmpty ? nil : subtitle, icon: UIApplicationShortcutIcon(systemImageName: symbol),
      userInfo: action.userInfo.mapValues { $0 as NSString })
  }
}

extension AppModel {
  /// The bot the icon's New chat starts with: the one a chat was last started with, else the first.
  var newChatProfile: String? {
    if !preferences.lastProfile.isEmpty, profile(named: preferences.lastProfile) != nil { return preferences.lastProfile }
    return orderedProfiles.first?.name
  }

  /// A chat came on screen and moves to the front. One just made here and not spoken in yet holds
  /// its place but stays off the icon until its first message lands (`recordSent`): until then the
  /// Mac has no such chat to open.
  func recordOpened(_ chat: ChatModel) {
    let chatTitle = row(chat.storedID)?.baseTitle ?? chat.savedTitle
    preferences.recentChats = preferences.recentChats.opened(
      profile: chat.profile, storedID: chat.storedID, title: chatTitle, botTitle: knownBotTitle(chat.profile),
      saved: !chat.isUnsaved)
    updateQuickActions()
  }

  /// A message from this phone landed: the chat exists on the Mac now. Only marks it saved: the send
  /// may finish after other chats were opened, or after the chat was archived here.
  func recordSent(_ chat: ChatModel) {
    preferences.recentChats = preferences.recentChats.saving(chat.storedID, title: chat.savedTitle)
    updateQuickActions()
  }

  /// The bot's name once the bot list has loaded; before that, empty keeps the name already saved.
  private func knownBotTitle(_ name: String) -> String {
    profiles.isEmpty ? "" : title(forProfile: name)
  }

  /// A fresh list read: titles may have changed, and chats archived on the Mac drop out. The list
  /// is a window, so recent chats it leaves out are read one by one.
  func refreshRecentChats(from rows: [SessionSummary]) {
    var bots: [String: String] = [:]
    for profile in profiles { bots[profile.name] = profile.title }
    preferences.recentChats = preferences.recentChats.refreshingTitles(from: rows, botTitles: bots)
    updateQuickActions()
    checkUnlistedRecentChats(rows)
  }

  /// Reads each recent chat the list left out (at most three): archived or deleted on the Mac drops
  /// it, an older chat keeps it, and a failed read changes nothing. One round at a time.
  private func checkUnlistedRecentChats(_ rows: [SessionSummary]) {
    guard recentChatsCheck == nil, let client else { return }
    let unlisted = preferences.recentChats.unlisted(in: rows)
    guard !unlisted.isEmpty else { return }
    recentChatsCheck = Task { [weak self] in
      let lookups = await RecentChats.lookUp(unlisted) { entry in
        try await client.session(storedID: entry.storedID, profile: entry.profile)
      }
      guard let self else { return }
      recentChatsCheck = nil
      // Signed out or moved to another Mac meanwhile.
      guard self.client === client else { return }
      preferences.recentChats = preferences.recentChats.reconciling(lookups)
      updateQuickActions()
    }
  }

  func forgetRecentChat(_ storedID: String) {
    preferences.recentChats = preferences.recentChats.removing(storedID)
    updateQuickActions()
  }

  /// Hands the icon its quick actions. Only once the bots are known, so the New chat line names one.
  func updateQuickActions() {
    #if DEBUG
      if AppModel.seedsRecentChats { return }
    #endif
    guard phase == .ready, !profiles.isEmpty else { return }
    let newChat = newChatProfile.map { (profile: $0, botTitle: title(forProfile: $0)) }
    let items = preferences.recentChats.quickActions(newChat: newChat).map(\.shortcutItem)
    if UIApplication.shared.shortcutItems != items { UIApplication.shared.shortcutItems = items }
  }

  #if DEBUG
    /// `QuickActionTests` and screenshots with no Mac: `--seed-recents` puts made-up chats on the
    /// icon, and the screen shows what a tapped one asked for (`PushCenter.openTrace`).
    func seedRecentChatsIfAsked() {
      guard ProcessInfo.processInfo.arguments.contains("--seed-recents") else { return }
      UserDefaults.standard.set(true, forKey: "debug.seedRecents")
      let seeded = RecentChats()
        .opened(profile: "default", storedID: "seed-3", title: "", botTitle: "Hermes")
        .opened(profile: "ada", storedID: "seed-2", title: "Plan the team offsite in Lisbon next spring", botTitle: "Ada")
        .opened(profile: "default", storedID: "seed-1", title: "Fix the flaky checkout test", botTitle: "Hermes")
      preferences.recentChats = seeded
      UIApplication.shared.shortcutItems = seeded.quickActions(newChat: (profile: "ada", botTitle: "Ada")).map(\.shortcutItem)
    }

    /// Kept for launches the icon makes itself (a cold open in `QuickActionTests`) until a launch
    /// with `--no-seed-recents`.
    static var seedsRecentChats: Bool {
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--no-seed-recents") { UserDefaults.standard.removeObject(forKey: "debug.seedRecents") }
      return arguments.contains("--seed-recents") || UserDefaults.standard.bool(forKey: "debug.seedRecents")
    }
  #endif
}
