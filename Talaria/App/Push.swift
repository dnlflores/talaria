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
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // A Live Activity the Mac starts wakes the app in the background with no screen: its update
    // token has to be caught and handed to the Mac from here.
    PushCenter.shared.observeActivities()
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    PushCenter.shared.deviceTokenArrived(PushRegistration.hex(deviceToken))
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    PushCenter.shared.registrationFailed(error.localizedDescription)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let chat = ChatRef(userInfo: notification.request.content.userInfo)
    let onScreen = await MainActor.run { PushCenter.shared.isOnScreen(chat) }
    return onScreen ? [] : [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let chat = ChatRef(userInfo: response.notification.request.content.userInfo) else { return }
    await MainActor.run { PushCenter.shared.open(chat) }
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
  @ObservationIgnored private var registerTask: Task<Void, Never>?
  @ObservationIgnored private var lastRegistered: (PushRegistration, Date)?
  @ObservationIgnored private var pendingOpen: ChatRef?
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

  /// This phone sent a message to a chat. With "Sent from this phone", that chat now notifies.
  func noteSent(storedID: String) {
    guard preferences.notifyScope == PushRegistration.Scope.phone.rawValue, let http else { return }
    let deviceID = deviceID
    Task { try? await http.followForPush(deviceID: deviceID, sessionID: storedID) }
  }

  // MARK: Live Activities

  func observeActivities() {
    guard !observing else { return }
    observing = true
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
        self?.watch(activity)
      }
    }
    for activity in Activity<ChatActivityAttributes>.activities { watch(activity) }
  }

  /// Hands each activity's update token to the Mac, so it can update and end that activity.
  private func watch(_ activity: Activity<ChatActivityAttributes>) {
    guard watched.insert(activity.id).inserted else { return }
    let attributes = activity.attributes
    Task { [weak self] in
      for await data in activity.pushTokenUpdates {
        await self?.sendActivityToken(PushRegistration.hex(data), for: attributes)
      }
    }
  }

  private func sendActivityToken(_ token: String, for attributes: ChatActivityAttributes) async {
    guard let http, http.hasSession else { return }
    // Often runs in a background wake: ask for the seconds the request needs.
    let task = UIApplication.shared.beginBackgroundTask(withName: "talaria.activity-token")
    defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
    for attempt in 0..<3 {
      do {
        try await http.registerActivity(
          deviceID: deviceID, sessionID: attributes.sessionID, profile: attributes.profile, token: token)
        return
      } catch HermesError.http(let status, _) where status == 404 {
        // The Mac does not know this phone yet (first launch): register, then try again.
        lastRegistered = nil
        await register(force: true)
      } catch {
        try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
      }
    }
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

  /// A notification or Live Activity was tapped.
  func open(_ chat: ChatRef) {
    guard let app, app.phase == .ready else {
      pendingOpen = chat
      return
    }
    if app.openChat?.storedID == chat.sessionID { return }
    app.openChat(profile: chat.profile, storedID: chat.sessionID)
  }

  /// A tap that launched the app opens its chat once the app is ready.
  func openPending() {
    guard let chat = pendingOpen else { return }
    pendingOpen = nil
    open(chat)
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
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
      }
    }
  #endif
}
