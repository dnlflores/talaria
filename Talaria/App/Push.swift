import ActivityKit
import HermesKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// A chat a notification or Live Activity points at.
struct ChatRef: Sendable, Equatable {
  var profile: String
  var sessionID: String

  /// From a notification's payload (`talaria: {profile, session_id}`, set by the Mac's plugin).
  init?(userInfo: [AnyHashable: Any]) {
    guard let talaria = userInfo["talaria"] as? [String: Any], let session = talaria["session_id"] as? String,
      !session.isEmpty
    else { return nil }
    self.init(profile: talaria["profile"] as? String ?? "default", sessionID: session)
  }

  /// From a Live Activity tap: `talaria://chat?profile=<bot>&session=<id>`.
  init?(url: URL) {
    guard url.scheme == "talaria", url.host == "chat",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let session = items.first(where: { $0.name == "session" })?.value, !session.isEmpty
    else { return nil }
    self.init(profile: items.first(where: { $0.name == "profile" })?.value ?? "default", sessionID: session)
  }

  init(profile: String, sessionID: String) {
    self.profile = profile
    self.sessionID = sessionID
  }
}

/// UIKit's half of notifications: the APNs device token, and notifications arriving or tapped.
///
/// The notification delegate methods are main-actor isolated (hence `@preconcurrency`): iOS calls
/// them on the main thread and expects their completion there too. As `nonisolated async` methods,
/// Swift finished them on a background thread, and UIKit aborted on its main-thread assertion while
/// saving the app's snapshot after a tap (`_performBlockAfterCATransactionCommitSynchronizes`).
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // A Live Activity the Mac starts wakes the app in the background with no screen: its update
    // token has to be caught and handed to the Mac from here.
    PushCenter.shared.observeActivities()
    return true
  }

  /// The app icon's quick actions reach the app through its scene: SwiftUI still draws the window,
  /// `QuickActionSceneDelegate` only takes the action.
  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = QuickActionSceneDelegate.self
    return configuration
  }

  /// The finished and needs-you notifications wake the app (`content-available`) with the chat's
  /// new Live Activity state.
  func application(
    _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    await PushCenter.shared.applyActivityState(from: userInfo) ? .newData : .noData
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushCenter.shared.deviceTokenArrived(PushRegistration.hex(deviceToken))
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    PushCenter.shared.registrationFailed(error.localizedDescription)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let chat = ChatRef(userInfo: notification.request.content.userInfo)
    return PushCenter.shared.isOnScreen(chat) ? [] : [.banner, .list, .sound]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let chat = ChatRef(userInfo: response.notification.request.content.userInfo) else { return }
    PushCenter.shared.open(chat)
  }
}

/// Notifications and Live Activities: asks iOS for permission and tokens, and keeps the Mac's
/// `talaria-push` plugin told where to send them. The Mac decides when; this only registers.
@MainActor @Observable
final class PushCenter {
  static let shared = PushCenter()

  @ObservationIgnored weak var app: AppModel?

  private(set) var authorization: UNAuthorizationStatus = .notDetermined
  private(set) var macState: PushMacState = .unknown
  private(set) var isTesting = false
  private(set) var testResult: String?

  @ObservationIgnored private var deviceToken: String?
  @ObservationIgnored private var pushToStartToken: String?
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var watched: Set<String> = []
  /// The update token last handed to the Mac for each activity id.
  @ObservationIgnored private var sentTokens: [String: String] = [:]
  @ObservationIgnored private var sendingTokens: Set<String> = []
  @ObservationIgnored private var registerTask: Task<Void, Never>?
  @ObservationIgnored private var lastRegistered: (PushRegistration, Date)?
  /// What a tap before the app was ready asked for.
  private enum Pending {
    case chat(ChatRef)
    case newChat(profile: String)
  }
  @ObservationIgnored private var pendingOpen: Pending?
  @ObservationIgnored private let defaults = UserDefaults.standard

  private init() {}

  /// How this build was signed: which APNs host its tokens belong to.
  let signing: SigningFacts = {
    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif
    let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
    return SigningFacts.from(provisioningProfile: url.flatMap { try? Data(contentsOf: $0) }, simulator: simulator)
  }()

  /// Stable for this install: the Mac keys its record of the phone by it.
  var deviceID: String {
    if let saved = defaults.string(forKey: "push.deviceID") { return saved }
    let fresh = UUID().uuidString
    defaults.set(fresh, forKey: "push.deviceID")
    return fresh
  }

  private var preferences: Preferences { app?.preferences ?? Preferences() }

  /// REST to the Mac: the app's client when it has one, else one built from what is saved (a
  /// background wake has no screen and no `AppModel` session yet).
  private var http: HermesHTTP? {
    if let client = app?.client { return client.http }
    let saved = preferences.serverAddress.isEmpty ? Preferences.bundledServerAddress : preferences.serverAddress
    guard let endpoint = ServerEndpoint(userInput: saved) else { return nil }
    return HermesHTTP(endpoint: endpoint, signIns: AppModel.makeSignInStore())
  }

  // MARK: Starting

  /// Signed in and on screen: ask for permission (once), the device token, and register.
  func start(asking: Bool) async {
    observeActivities()
    await refreshAuthorization()
    if authorization == .notDetermined, asking, preferences.notifyFinished {
      await requestAuthorization()
    }
    UIApplication.shared.registerForRemoteNotifications()
    scheduleRegister()
  }

  func becameActive() {
    Task {
      await refreshAuthorization()
      scheduleRegister()
      await sendMissingActivityTokens()
    }
  }

  func refreshAuthorization() async {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    if status != authorization { authorization = status }
  }

  func requestAuthorization() async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    await refreshAuthorization()
  }

  func deviceTokenArrived(_ token: String) {
    guard token != deviceToken else { return }
    deviceToken = token
    scheduleRegister()
  }

  func registrationFailed(_ message: String) {
    // The simulator without push support, or a build without the push entitlement.
    if macState == .unknown { macState = .failed("iOS gave no push token: \(message)") }
  }

  /// Settings changed, or the bot list (their names ride along).
  func settingsChanged() {
    scheduleRegister(force: true)
  }

  // MARK: Registering with the Mac

  private func scheduleRegister(force: Bool = false) {
    registerTask?.cancel()
    registerTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard let self, !Task.isCancelled else { return }
      await self.register(force: force)
    }
  }

  private func registration() -> PushRegistration {
    let preferences = preferences
    var bots: [String: String] = [:]
    for profile in app?.profiles ?? [] { bots[profile.name] = profile.title }
    return PushRegistration(
      deviceID: deviceID, name: UIDevice.current.name, token: deviceToken, pushToStartToken: pushToStartToken,
      environment: signing.environment, topic: Bundle.main.bundleIdentifier ?? "", teamID: signing.teamID,
      alerts: preferences.notifyFinished, liveActivities: preferences.liveActivities,
      scope: PushRegistration.Scope(rawValue: preferences.notifyScope) ?? .all, bots: bots)
  }

  private func register(force: Bool) async {
    guard app?.phase == .ready, let http, http.hasSession else { return }
    let current = registration()
    guard current.token != nil || current.pushToStartToken != nil else { return }
    // Re-registered at most hourly when nothing changed.
    if !force, let (last, at) = lastRegistered, last == current, Date().timeIntervalSince(at) < 3600 { return }
    do {
      macState = try await http.registerPush(current)
      lastRegistered = (current, Date())
    } catch HermesError.loginRequired {
      macState = .unknown
    } catch {
      macState = .failed(error.localizedDescription)
    }
  }

  /// Signing out: the Mac stops sending to this phone.
  func unregister() async {
    guard let http, http.hasSession else { return }
    try? await http.unregisterPush(deviceID: deviceID)
    lastRegistered = nil
    macState = .unknown
  }

  func sendTest() async {
    guard let http else { return }
    isTesting = true
    defer { isTesting = false }
    await register(force: true)
    do {
      let answer = try await http.sendTestPush(deviceID: deviceID)
      testResult = answer.ok ? "Sent. It should arrive in a moment." : "Apple refused it: \(answer.reason)"
    } catch {
      testResult = "Could not send: \(error.localizedDescription)"
    }
  }

  /// This phone sent a message to a chat. With "Sent from this phone", that chat now notifies; and
  /// the reply gets its Live Activity from here at once.
  func noteSent(profile: String, storedID: String, title: String) {
    if preferences.notifyScope == PushRegistration.Scope.phone.rawValue, let http {
      let deviceID = deviceID
      Task { try? await http.followForPush(deviceID: deviceID, sessionID: storedID) }
    }
    startActivity(profile: profile, sessionID: storedID, title: title)
  }

  /// An activity the app starts itself, unlike one the Mac starts by push, gets its update token
  /// (`pushTokenUpdates`), so the Mac can show every step on it. It reaches the Mac well before the
  /// Mac would start one of its own (`START_AFTER` in the plugin), which then updates this one.
  private func startActivity(profile: String, sessionID: String, title: String) {
    let mine = Activity<ChatActivityAttributes>.activities.filter { $0.attributes.sessionID == sessionID }
    guard preferences.liveActivities, macState == .ready, ActivityAuthorizationInfo().areActivitiesEnabled,
      !mine.contains(where: { $0.activityState == .active })
    else { return }
    // The last reply's "Done" would otherwise sit beside the new one for its ten minutes.
    let finished = Set(mine.map(\.id))
    if !finished.isEmpty {
      Task {
        for activity in Activity<ChatActivityAttributes>.activities where finished.contains(activity.id) {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
    }
    let bot = app?.profiles.first(where: { $0.name == profile })?.title ?? "Hermes"
    let attributes = ChatActivityAttributes(profile: profile, sessionID: sessionID, botName: bot, chatTitle: title)
    let state = ChatActivityAttributes.ContentState(phase: .working, startedAt: Date().timeIntervalSince1970, title: title)
    do {
      let activity = try Activity.request(
        attributes: attributes, content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)),
        pushType: .token)
      PushCenter.trace("started here \(activity.id) \(sessionID.prefix(14))")
    } catch {
      PushCenter.trace("could not start here: \(error)")
    }
  }

  // MARK: Live Activities

  func observeActivities() {
    guard !observing else { return }
    observing = true
    PushCenter.trace("observeActivities, \(Activity<ChatActivityAttributes>.activities.count) running, app state \(UIApplication.shared.applicationState.rawValue)")
    Task { [weak self] in
      for await data in Activity<ChatActivityAttributes>.pushToStartTokenUpdates {
        guard let self else { return }
        let token = PushRegistration.hex(data)
        if token != self.pushToStartToken {
          self.pushToStartToken = token
          self.scheduleRegister()
        }
      }
    }
    Task { [weak self] in
      for await activity in Activity<ChatActivityAttributes>.activityUpdates {
        PushCenter.trace("activityUpdates \(activity.id) \(activity.attributes.sessionID.prefix(14)) state=\(activity.activityState)")
        self?.watch(activity)
      }
    }
    for activity in Activity<ChatActivityAttributes>.activities { watch(activity) }
  }

  /// Hands each activity's update token to the Mac, so it can update and end that activity.
  ///
  /// An activity the Mac started by push wakes the app in the background, and the app is
  /// suspended again within moments: the token usually comes a beat after the activity, and
  /// `pushTokenUpdates` then never yields (seen on iOS 27, simulator and iPhone). So the app asks
  /// for background time while it waits, and also reads `pushToken` itself until it shows up.
  private func watch(_ activity: Activity<ChatActivityAttributes>) {
    guard watched.insert(activity.id).inserted else { return }
    let id = activity.id
    PushCenter.trace("watch \(id) token-now=\(activity.pushToken != nil)")
    Task { [weak self] in
      for await data in activity.pushTokenUpdates {
        PushCenter.trace("pushTokenUpdates \(id)")
        await self?.sendActivityToken(PushRegistration.hex(data), activityID: id)
      }
    }
    guard activity.activityState == .active, !activity.content.state.isOver else { return }
    let wait = UIApplication.shared.beginBackgroundTask(withName: "talaria.activity-token-wait")
    Task { [weak self] in
      defer { if wait != .invalid { UIApplication.shared.endBackgroundTask(wait) } }
      for _ in 0..<25 {
        if let self, self.sentTokens[id] != nil { return }
        if let data = Activity<ChatActivityAttributes>.activities.first(where: { $0.id == id })?.pushToken {
          PushCenter.trace("pushToken read \(id)")
          await self?.sendActivityToken(PushRegistration.hex(data), activityID: id)
          return
        }
        try? await Task.sleep(for: .seconds(1))
      }
      PushCenter.trace("no token for \(id) after 25s")
    }
  }

  /// Moves a chat's Live Activity to the state a notification carries. iOS 27 does not hand the app
  /// the update token of an activity the Mac started by push (seen on simulator and iPhone: the
  /// app only ever gets the push-to-start token), so the Mac cannot update that activity itself;
  /// its finished and needs-you notifications wake the app to do it instead.
  func applyActivityState(from userInfo: [AnyHashable: Any]) async -> Bool {
    guard let chat = ChatRef(userInfo: userInfo),
      let custom = userInfo["talaria"] as? [String: Any],
      let raw = custom["state"],
      let data = try? JSONSerialization.data(withJSONObject: raw),
      let state = try? JSONDecoder().decode(ChatActivityAttributes.ContentState.self, from: data)
    else { return false }
    var applied = false
    for activity in Activity<ChatActivityAttributes>.activities
    where activity.attributes.sessionID == chat.sessionID && activity.attributes.profile == chat.profile
      && activity.activityState == .active
    {
      let content = ActivityContent(state: state, staleDate: nil)
      if state.isOver {
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(10 * 60)))
      } else {
        await activity.update(content)
      }
      applied = true
    }
    PushCenter.trace("applyActivityState \(chat.sessionID.prefix(14)) \(state.phase) applied=\(applied)")
    return applied
  }

  /// Tokens that came while the app was suspended, picked up on the next open.
  private func sendMissingActivityTokens() async {
    for activity in Activity<ChatActivityAttributes>.activities where activity.activityState == .active {
      guard let data = activity.pushToken else { continue }
      await sendActivityToken(PushRegistration.hex(data), activityID: activity.id)
    }
  }

  private func sendActivityToken(_ token: String, activityID: String) async {
    guard sentTokens[activityID] != token, !sendingTokens.contains(token),
      let attributes = Activity<ChatActivityAttributes>.activities.first(where: { $0.id == activityID })?.attributes,
      let http, http.hasSession
    else { return }
    sendingTokens.insert(token)
    defer { sendingTokens.remove(token) }
    // Often runs in a background wake: ask for the seconds the request needs.
    let task = UIApplication.shared.beginBackgroundTask(withName: "talaria.activity-token")
    defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
    for attempt in 0..<3 {
      do {
        try await http.registerActivity(
          deviceID: deviceID, sessionID: attributes.sessionID, profile: attributes.profile, token: token)
        sentTokens[activityID] = token
        PushCenter.trace("registerActivity ok \(attributes.sessionID.prefix(14))")
        return
      } catch HermesError.http(let status, _) where status == 404 {
        // The Mac does not know this phone yet (first launch): register, then try again.
        lastRegistered = nil
        await register(force: true)
      } catch {
        PushCenter.trace("registerActivity failed: \(error)")
        try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
      }
    }
  }

  /// DEBUG builds keep a trace of the Live Activity token hand-off in Documents/push-trace.log,
  /// readable from the Mac (`simctl get_app_container`, `devicectl device copy from`).
  nonisolated static func trace(_ line: String) {
    #if DEBUG
      guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
      let url = folder.appendingPathComponent("push-trace.log")
      let stamp = ISO8601DateFormatter().string(from: Date())
      let data = Data("\(stamp) \(line)\n".utf8)
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
      } else {
        try? data.write(to: url)
      }
    #endif
  }

  /// A chat was opened: its notifications have been seen, and a finished activity for it can go.
  func chatOpened(storedID: String) {
    Task {
      let center = UNUserNotificationCenter.current()
      let delivered = await center.deliveredNotifications()
      let ids = delivered.filter { ChatRef(userInfo: $0.request.content.userInfo)?.sessionID == storedID }
        .map(\.request.identifier)
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
    Task {
      for activity in Activity<ChatActivityAttributes>.activities where activity.attributes.sessionID == storedID {
        if activity.content.state.isOver || activity.activityState == .ended {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
      }
    }
  }

  /// The inbox just loaded: an activity still saying Working for a chat that has stopped (its end
  /// push never came, say the token never reached the Mac) is ended here.
  func reconcile(isBusy: (String) -> Bool) {
    let now = Date().timeIntervalSince1970
    let stale = Set(
      Activity<ChatActivityAttributes>.activities.filter { activity in
        let state = activity.content.state
        #if DEBUG
          if activity.attributes.sessionID == "demo" { return false }  // startDemoActivityIfAsked
        #endif
        return activity.activityState == .active && !state.isOver && now - state.startedAt > 120
          && !isBusy(activity.attributes.sessionID)
      }.map(\.id))
    guard !stale.isEmpty else { return }
    Task {
      for activity in Activity<ChatActivityAttributes>.activities where stale.contains(activity.id) {
        var ended = activity.content.state
        ended.phase = .done
        ended.endedAt = now
        ended.step = nil
        await activity.end(
          ActivityContent(state: ended, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(10 * 60)))
      }
    }
  }

  // MARK: Opening chats

  func isOnScreen(_ chat: ChatRef?) -> Bool {
    guard let chat, UIApplication.shared.applicationState == .active else { return false }
    return app?.openChat?.storedID == chat.sessionID
  }

  /// A notification, Live Activity or the app icon's quick action was tapped.
  func open(_ chat: ChatRef) {
    traceOpen("chat \(chat.profile)/\(chat.sessionID)")
    guard let app, app.phase == .ready else {
      pendingOpen = .chat(chat)
      return
    }
    if app.openChat?.storedID == chat.sessionID { return }
    app.openChat(profile: chat.profile, storedID: chat.sessionID)
  }

  /// The app icon's New chat: a chat with this bot, as the dock's New chat starts one.
  func startChat(profile: String) {
    traceOpen("new chat \(profile)")
    guard let app, app.phase == .ready else {
      pendingOpen = .newChat(profile: profile)
      return
    }
    Task { await app.startChat(profile: profile) }
  }

  /// What the app icon asked for. Waits for sign-in like a tapped notification does.
  func perform(_ action: QuickAction) {
    switch action {
    case .chat(let profile, let storedID): open(ChatRef(profile: profile, sessionID: storedID))
    case .newChat(let profile): startChat(profile: profile)
    }
  }

  /// A tap that launched the app (or came before sign-in) runs once the app is ready.
  func openPending() {
    guard let pending = pendingOpen else { return }
    pendingOpen = nil
    switch pending {
    case .chat(let chat): open(chat)
    case .newChat(let profile): startChat(profile: profile)
    }
  }

  #if DEBUG
    /// The last chat a tap asked for and whether it waits for sign-in, shown on screen for
    /// `QuickActionTests` (`--seed-recents`).
    private(set) var openTrace = ""
  #endif

  private func traceOpen(_ what: String) {
    #if DEBUG
      openTrace = what + (app?.phase == .ready ? "" : " (waiting for sign-in)")
    #endif
  }

  #if DEBUG
    /// The Live Activity without a Mac, for simulator screenshots and `ActivityLookTests`:
    /// `TALARIA_DEMO_ACTIVITY=working|waiting|done|failed`.
    func startDemoActivityIfAsked() {
      guard let raw = ProcessInfo.processInfo.environment["TALARIA_DEMO_ACTIVITY"],
        let phase = ChatActivityAttributes.Phase(rawValue: raw)
      else { return }
      let now = Date().timeIntervalSince1970
      let attributes = ChatActivityAttributes(
        profile: "default", sessionID: "demo", botName: "Hermes", chatTitle: "Fix the flaky checkout test")
      var state = ChatActivityAttributes.ContentState(phase: phase, startedAt: now - 133)
      switch phase {
      case .working: state.step = "Editing a file: CheckoutTests.swift"
      case .waiting: state.step = "Should I open the pull request now?"
      case .done, .stopped:
        state.endedAt = now
        state.summary = "The checkout test waits for the cart to load now, and the pull request is up."
      case .failed:
        state.endedAt = now
        state.summary = "The build failed: CheckoutTests.swift:42 has a type error."
      }
      Task {
        for activity in Activity<ChatActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        let push = ProcessInfo.processInfo.environment["TALARIA_DEMO_ACTIVITY_PUSH"] == "1"
        do {
          let activity = try Activity.request(
            attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: push ? .token : nil)
          PushCenter.trace("demo requested \(activity.id) push=\(push)")
        } catch {
          PushCenter.trace("demo request failed: \(error)")
        }
      }
    }

    /// A notification shaped like the Mac's, for `NotificationTapTests`: tapping it runs the same
    /// delegate method a real one does. `TALARIA_TEST_NOTIFICATION=<profile>/<stored id>/<title>`,
    /// shown `TALARIA_TEST_NOTIFICATION_DELAY` seconds (default 6) after launch.
    func scheduleTestNotificationIfAsked() {
      let environment = ProcessInfo.processInfo.environment
      guard let raw = environment["TALARIA_TEST_NOTIFICATION"] else { return }
      let parts = raw.split(separator: "/", maxSplits: 2).map(String.init)
      guard parts.count == 3 else { return }
      let delay = Double(environment["TALARIA_TEST_NOTIFICATION_DELAY"] ?? "") ?? 6
      Task {
        await requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = "Hermes finished"
        content.subtitle = parts[2]
        content.body = "The reply is ready."
        content.userInfo = ["talaria": ["kind": "finished", "profile": parts[0], "session_id": parts[1]]]
        let request = UNNotificationRequest(
          identifier: "talaria.test", content: content,
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
      }
    }
  #endif
}
