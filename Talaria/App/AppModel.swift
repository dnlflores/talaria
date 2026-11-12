import HermesKit
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
  case chat(profile: String, storedID: String)
  case settings
}

struct ToastMessage: Identifiable, Equatable {
  enum Kind { case info, success, failure }
  let id = UUID()
  let text: String
  let kind: Kind
}

/// App-wide state: the connection to the Mac, the conversation list, and navigation.
@MainActor @Observable
final class AppModel {
  enum Phase: Equatable {
    case launching
    /// No address yet (first launch), or the saved one stopped working.
    case needsServer
    case needsPassword
    case ready
  }

  let preferences = Preferences()

  private(set) var phase: Phase = .launching
  private(set) var connection: ConnectionState = .idle
  private(set) var endpoint: ServerEndpoint?
  private(set) var client: HermesClient?

  private(set) var sessions: [SessionSummary] = []
  private(set) var families: [String: SessionFamily] = [:]
  private(set) var owners: [String: ChatOwner] = [:]
  private(set) var profiles: [Profile] = []
  private(set) var avatars: [String: UIImage] = [:]
  private(set) var hasLoadedSessions = false
  private(set) var sessionsError: String?
  private(set) var hermesVersion = ""
  private(set) var macHome = ""

  var path: [Route] = []
  private(set) var toast: ToastMessage?
  /// Approval, sudo and secret requests waiting for an answer; the first one is on screen.
  private(set) var prompts: [ServerRequest] = []
  /// Stored ids of conversations with an unanswered request.
  private(set) var waitingOnYou: Set<String> = []

  private(set) var openChat: ChatModel?
  @ObservationIgnored private var chatCache: [String: ChatModel] = [:]
  @ObservationIgnored private var liveToStored: [String: String] = [:]

  private let cookies = KeychainCookieStore(service: "talaria.gate-session")
  private var pump: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?
  private var toastTask: Task<Void, Never>?
  private var releaseTasks: [String: Task<Void, Never>] = [:]
  private var isLoadingSessions = false

  // MARK: Launch and sign-in

  func launch() async {
    guard phase == .launching else { return }
    #if DEBUG
      if let override = ProcessInfo.processInfo.environment["TALARIA_SERVER"], !override.isEmpty {
        preferences.serverAddress = override
      }
    #endif
    let saved = preferences.serverAddress.isEmpty ? Preferences.bundledServerAddress : preferences.serverAddress
    guard let endpoint = ServerEndpoint(userInput: saved) else {
      phase = .needsServer
      return
    }
    adopt(endpoint)
    if client?.http.hasSession == true {
      // Signed in before: show the list right away and let the socket decide whether the session still holds.
      enterReady()
      return
    }
    do {
      try await resolveGate()
    } catch {
      phase = .needsServer
    }
  }

  /// Checks a typed address. Throws with a message for the connect screen.
  func connect(to address: String) async throws {
    guard let endpoint = ServerEndpoint(userInput: address) else {
      throw HermesError.notAHermesGate("not a valid address")
    }
    adopt(endpoint)
    try await resolveGate()
    preferences.serverAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolveGate() async throws {
    guard let client else { return }
    switch try await client.http.probe() {
    case .open(let health):
      macHome = health.home
      enterReady()
    case .loginRequired:
      phase = .needsPassword
    case .noPasswordConfigured:
      throw HermesError.noPasswordConfigured
    }
  }

  func signIn(password: String) async throws {
    guard let client else { return }
    try await client.http.login(password: password)
    enterReady()
  }

  /// Forgets the session and returns to the password screen. The address is kept for next time.
  func signOut() async {
    let old = client
    teardown()
    await old?.http.logout()
    // The old client's event stream ended with its pump, so the next sign-in gets a fresh one.
    client = endpoint.map { HermesClient(endpoint: $0, cookies: cookies) }
    phase = endpoint == nil ? .needsServer : .needsPassword
  }

  func forgetServer() async {
    await signOut()
    preferences.serverAddress = ""
    endpoint = nil
    client = nil
    phase = .needsServer
  }

  private func adopt(_ endpoint: ServerEndpoint) {
    if endpoint == self.endpoint, client != nil { return }
    teardown()
    self.endpoint = endpoint
    client = HermesClient(endpoint: endpoint, cookies: cookies)
  }

  private func teardown() {
    pump?.cancel()
    pump = nil
    reloadTask?.cancel()
    reloadTask = nil
    for task in releaseTasks.values { task.cancel() }
    releaseTasks = [:]
    if let client { Task { await client.rpc.stop() } }
    client = nil
    path = []
    openChat = nil
    chatCache = [:]
    sessions = []
    families = [:]
    owners = [:]
    profiles = []
    avatars = [:]
    prompts = []
    waitingOnYou = []
    liveToStored = [:]
    hasLoadedSessions = false
    connection = .idle
  }

  private func enterReady() {
    guard let client else { return }
    phase = .ready
    if pump == nil {
      pump = Task { [weak self] in
        for await incoming in client.rpc.incoming {
          guard let self, !Task.isCancelled else { return }
          self.handle(incoming, from: client)
        }
      }
    }
    Task { await client.rpc.start() }
    Task { await refreshSessions() }
    Task { await refreshStatus() }
  }

  /// Foreground: the socket has usually died while the phone slept.
  func becameActive() {
    guard phase == .ready, let client else { return }
    Task { await client.rpc.kick() }
    Task { await refreshSessions(quiet: true) }
  }

  // MARK: Incoming

  private func handle(_ incoming: RPCConnection.Incoming, from source: HermesClient) {
    guard source === client else { return }
    switch incoming {
    case .state(let state):
      connection = state
      switch state {
      case .open:
        Task { await refreshProfiles() }
        Task { await refreshSessions(quiet: true) }
        if let chat = openChat { Task { await chat.connectionReady() } }
      case .unauthorized:
        if phase == .ready {
          cookies.setCookie(nil, for: source.endpoint)
          path = []
          phase = .needsPassword
          show("Your session on the Mac ended. Sign in again.", kind: .info)
        }
      default:
        break
      }

    case .event(let event):
      if event.sessionID.isEmpty {
        switch event.type {
        case "sessions.changed": scheduleReload()
        case "platforms.changed": Task { await refreshStatus() }
        case "session.reclaimed":
          if let reclaimed = event.payload["session_id"].string, let chat = openChat, chat.liveID == reclaimed {
            Task { await chat.liveSessionReclaimed() }
          }
        default: break
        }
      } else if let chat = openChat, chat.liveID == event.sessionID {
        chat.handle(event)
      }

    case .request(let request):
      deliver(request)
    }
  }

  /// Routes a question from the gateway to where it can be answered.
  func deliver(_ request: ServerRequest) {
    switch request.method {
    case "approval", "sudo", "secret":
      if !prompts.contains(where: { $0.id == request.id }) {
        prompts.append(request)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
      }
    case "clarify":
      if let chat = openChat, !chat.isLoading, request.sessionID.isEmpty || request.sessionID == chat.liveID {
        chat.attach(clarify: request)
      } else {
        // It stays open on the backend; resuming that chat delivers it again.
        show("A bot is asking you something. Open that chat to answer.", kind: .info)
        scheduleReload()
      }
    default:
      guard let client else { return }
      Task { await client.rpc.reject(request) }
      return
    }
    if let stored = liveToStored[request.sessionID] { waitingOnYou.insert(stored) }
  }

  func resolve(_ request: ServerRequest, result: JSONValue?) {
    prompts.removeAll { $0.id == request.id }
    if let stored = liveToStored[request.sessionID] { waitingOnYou.remove(stored) }
    guard let client else { return }
    Task {
      if let result {
        await client.answer(request, result: result)
      } else {
        await client.decline(request)
      }
    }
  }

  func requestWithdrawn(_ id: String) {
    prompts.removeAll { $0.id == id }
  }

  func clearWaiting(storedID: String) {
    waitingOnYou.remove(storedID)
  }

  func noteLive(_ liveID: String, storedID: String) {
    liveToStored[liveID] = storedID
  }

  /// A short name for the bot behind a live session, for prompts.
  func botTitle(forLive liveID: String) -> String? {
    guard let stored = liveToStored[liveID], let row = sessions.first(where: { $0.id == stored }) else {
      return openChat.flatMap { $0.liveID == liveID ? title(forProfile: $0.profile) : nil }
    }
    return title(forProfile: row.profile)
  }

  // MARK: Lists

  func refreshSessions(quiet: Bool = false) async {
    guard let client, !isLoadingSessions else { return }
    isLoadingSessions = true
    defer { isLoadingSessions = false }
    async let ownersJob = try? client.owners()
    do {
      let rows = try await client.sessions()
      let currentOwners = await ownersJob ?? owners
      if rows != sessions {
        sessions = rows
        families = SessionGrouping.families(rows)
      }
      setOwners(currentOwners)
      sessionsError = nil
      hasLoadedSessions = true
      if let chat = openChat, let row = rows.first(where: { $0.id == chat.storedID }) { chat.rowChanged(row) }
    } catch HermesError.loginRequired {
      connection = .unauthorized
      if phase == .ready {
        path = []
        phase = .needsPassword
      }
    } catch {
      _ = await ownersJob
      sessionsError = error.localizedDescription
      hasLoadedSessions = true
      if !quiet { show("Could not load chats: \(error.localizedDescription)", kind: .failure) }
    }
  }

  @discardableResult
  func refreshOwners() async -> [String: ChatOwner] {
    guard let client, let fresh = try? await client.owners() else { return owners }
    setOwners(fresh)
    return fresh
  }

  private func setOwners(_ fresh: [String: ChatOwner]) {
    guard fresh != owners else { return }
    owners = fresh
    openChat?.ownersChanged()
  }

  func scheduleReload(after seconds: Double = 1.2) {
    guard reloadTask == nil else { return }
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, !Task.isCancelled else { return }
      self.reloadTask = nil
      await self.refreshSessions(quiet: true)
    }
  }

  private func refreshProfiles() async {
    guard let client, let list = try? await client.profiles() else { return }
    profiles = list
    for profile in list where profile.hasAvatar && avatars[profile.name] == nil {
      Task {
        if let data = try? await client.avatar(profile: profile.name), let image = UIImage(data: data) {
          avatars[profile.name] = image
        }
      }
    }
  }

  private func refreshStatus() async {
    guard let client else { return }
    if macHome.isEmpty, case .open(let health)? = try? await client.http.probe() { macHome = health.home }
    guard let status = try? await client.status() else { return }
    hermesVersion = status["version"].stringValue
  }

  func profile(named name: String) -> Profile? {
    profiles.first { $0.name == name }
  }

  func title(forProfile name: String) -> String {
    profile(named: name)?.title ?? (name == "default" ? "Hermes" : name)
  }

  func family(of storedID: String) -> SessionFamily? { families[storedID] }

  func row(_ storedID: String) -> SessionSummary? {
    sessions.first { $0.id == storedID }
  }

  /// Rows of one section, one per conversation family, filtered by bot and search text.
  func rows(in section: SessionSection, query: String) -> [SessionSummary] {
    let filter = preferences.profileFilter
    let inSection = sessions.filter { $0.section == section && (filter.isEmpty || $0.profile == filter) }
    return SessionGrouping.collapse(inSection, families: families).filter { $0.matches(query) }
  }

  /// Sections that exist besides Chats, in a stable order.
  var extraSections: [SessionSection] {
    var seen = Set<SessionSection>()
    var out: [SessionSection] = []
    for session in sessions {
      let section = session.section
      if section != .chats, seen.insert(section).inserted { out.append(section) }
    }
    return out.sorted { $0.label < $1.label }
  }

  // MARK: Row actions

  func setPinned(_ session: SessionSummary, _ pinned: Bool) {
    mutate(session, failure: "Could not change the pin") { client in
      try await client.update(session, pinned: pinned)
    }
  }

  func setUnread(_ session: SessionSummary, _ unread: Bool) {
    mutate(session, failure: "Could not update the chat") { client in
      try await client.update(session, unread: unread)
    }
  }

  func archive(_ session: SessionSummary) {
    sessions.removeAll { $0.id == session.id }
    mutate(session, failure: "Could not archive the chat") { client in
      try await client.setArchived(storedID: session.id, profile: session.profile, archived: true)
    }
  }

  private func mutate(_ session: SessionSummary, failure: String, _ work: @escaping @MainActor (HermesClient) async throws -> Void) {
    guard let client else { return }
    Task {
      do {
        try await work(client)
      } catch {
        show("\(failure): \(error.localizedDescription)", kind: .failure)
      }
      await refreshSessions(quiet: true)
    }
  }

  // MARK: Chats

  /// The model for a route. Models made ahead of navigation (a new chat, a new version) are
  /// handed over from the cache; anything else is built from the sidebar row.
  func chat(profile: String, storedID: String) -> ChatModel {
    if let cached = chatCache[storedID] { return cached }
    let model = ChatModel(app: self, profile: profile, storedID: storedID, row: row(storedID), live: nil)
    chatCache[storedID] = model
    return model
  }

  func open(_ session: SessionSummary) {
    path.append(.chat(profile: session.profile, storedID: session.id))
  }

  /// Starts an empty conversation with a bot and opens it. Nothing is stored until the first message.
  func startChat(profile: String) async {
    guard let client else { return }
    do {
      try await client.rpc.waitUntilReady(timeout: 30)
      let bot = self.profile(named: profile)
      let options = NewSessionOptions(model: bot?.model, provider: bot?.provider)
      let live = try await client.create(profile: profile, options: options)
      preferences.lastProfile = profile
      chatCache[live.storedID] = ChatModel(app: self, profile: profile, storedID: live.storedID, row: nil, live: live)
      path.append(.chat(profile: profile, storedID: live.storedID))
    } catch {
      show("Could not start a chat: \(error.localizedDescription)", kind: .failure)
    }
  }

  /// Swaps the chat on screen for another version of the same conversation.
  func replaceOpenChat(with model: ChatModel) {
    chatCache[model.storedID] = model
    showVersion(profile: model.profile, storedID: model.storedID)
  }

  func showVersion(profile: String, storedID: String) {
    let route = Route.chat(profile: profile, storedID: storedID)
    if let last = path.indices.last, case .chat = path[last] {
      path[last] = route
    } else {
      path.append(route)
    }
  }

  func chatAppeared(_ chat: ChatModel) {
    releaseTasks.removeValue(forKey: chat.storedID)?.cancel()
    openChat = chat
  }

  func chatDisappeared(_ chat: ChatModel) {
    chat.leave()
    if openChat === chat { openChat = nil }
    for (key, cached) in chatCache where cached === chat { chatCache[key] = nil }
  }

  /// A chat we talked in holds the backend's lease until its runtime closes, which locks it out of
  /// the desktop app. Let go shortly after leaving, unless a reply is still running.
  func scheduleRelease(liveID: String, storedID: String) {
    guard let client else { return }
    releaseTasks[storedID]?.cancel()
    releaseTasks[storedID] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(45))
      guard let self, !Task.isCancelled else { return }
      self.releaseTasks[storedID] = nil
      if self.openChat?.storedID == storedID { return }
      guard let active = try? await client.activeSessions(),
        let entry = active.first(where: { $0["id"].string == liveID })
      else { return }
      let status = entry["status"].stringValue.lowercased()
      if !status.isEmpty, !["idle", "ready", "waiting"].contains(where: status.contains) { return }
      try? await client.close(liveID: liveID)
    }
  }

  // MARK: Toasts

  func show(_ text: String, kind: ToastMessage.Kind = .info, seconds: Double = 3.2) {
    let message = ToastMessage(text: text, kind: kind)
    toast = message
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(kind == .failure ? max(seconds, 5) : seconds))
      guard let self, !Task.isCancelled, self.toast == message else { return }
      self.toast = nil
    }
  }

  func dismissToast() {
    toast = nil
  }
}
