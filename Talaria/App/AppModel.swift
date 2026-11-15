import HermesKit
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
  case chat(profile: String, storedID: String)
  /// Every conversation of one bot (iPhone; iPad shows it in the list column).
  case agent(profile: String)
  /// Areas with no place in the dock, stacked on Chats in one stack: Settings from the inbox's
  /// corner (Kanban and Cron open from the agent hub). In the split view they replace the list column.
  case kanban
  case cron
  case settings

  /// The route that shows an area on the Chats stack, for areas that have one.
  static func area(_ tab: AppTab) -> Route? {
    switch tab {
    case .kanban: return .kanban
    case .cron: return .cron
    case .settings: return .settings
    case .chats, .bots: return nil
    }
  }
}

/// Pages of the agent hub (the Agents area). On iPhone they stack over the hub, a chat opened
/// from them too; on iPad they stack in the detail column.
enum HubRoute: Hashable {
  case model(profile: String)
  case skills(profile: String)
  case soul(profile: String)
  case memory(profile: String)
  /// One memory from Memory & Learning, opened by its graph node id.
  case learning(profile: String, id: String, title: String)
  case cron(profile: String)
  case chats(profile: String)
  case kanban
  case chat(profile: String, storedID: String)
}

/// The top-level areas. Both docks hold Chats and Agents only. Settings opens from the inbox's
/// corner; New chat, Cron and Kanban open per bot from the agent hub.
enum AppTab: String, Hashable, CaseIterable, Identifiable {
  case chats, bots, kanban, cron, settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chats: return "Chats"
    case .bots: return "Agents"
    case .kanban: return "Kanban"
    case .cron: return "Cron"
    case .settings: return "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .chats: return "message"
    case .bots: return "circle.grid.cross"
    case .kanban: return "rectangle.split.3x1"
    case .cron: return "clock"
    case .settings: return "gearshape"
    }
  }
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
    /// Hermes on the Mac wants a sign-in (none held, or it ended).
    case needsSignIn
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
  /// How many conversations each bot has on the Mac, for "N more sessions".
  private(set) var agentTotals: [String: Int] = [:]
  /// The latest reply of each bot's lead conversation, by stored id.
  private(set) var headPreviews: [String: String] = [:]
  /// Where each chat started, backfilled on the Mac.
  private(set) var chatOrigins = ChatOriginMap.empty
  @ObservationIgnored private var chatOriginsReadAt: Date?
  @ObservationIgnored private var headPreviewStamps: [String: Double] = [:]
  /// The single-chat reads for recent chats a list read left out (`checkUnlistedRecentChats`).
  @ObservationIgnored var recentChatsCheck: Task<Void, Never>?
  /// When a chat started working, for chats seen going from idle to working. A chat already
  /// working when the app first looked has no entry: its start is not known.
  private(set) var workingSince: [String: Double] = [:]
  @ObservationIgnored private var workingSnapshot: Set<String>?

  var tab: AppTab = .chats
  /// The chat stack. On iPhone it sits on top of the inbox; on iPad its last entry is the chat
  /// shown beside the inbox.
  var path: [Route] = []
  /// The bot whose conversations the iPad list column shows instead of the inbox.
  var splitAgent: String?
  /// The agent hub's stack on iPhone.
  var hubPath: [HubRoute] = []
  /// The bot the iPhone agent hub shows. Empty: the bot used last, else the default one.
  var hubProfile = ""
  /// Models starred in the model chooser, shared with the desktop app (`FavoriteModels`).
  var favoriteModels: [String] = []
  @ObservationIgnored var favoritesLoaded = false
  /// Each bot's model catalog for its default model, and why one failed to load.
  var defaultCatalogs: [String: ModelCatalog] = [:]
  var defaultCatalogErrors: [String: String] = [:]
  /// Each bot's installed skills.
  var skillLists: [String: [SkillCategory]] = [:]
  /// The Chats area shows the inbox and a chat side by side (iPad, regular width).
  var usesSplitLayout = false
  /// The areas are in the side dock (iPad, an unfolded iPhone Duo), not the bottom dock.
  var showsSideDock = false
  /// What the Bots, Kanban and Cron areas have open.
  private(set) var areas = AreaState()
  /// Live session status by stored id (`working`, `waiting`, `idle`), from the backend's active list.
  private(set) var liveStatuses: [String: String] = [:]
  /// Membership is distinct from turn status. A known idle/starting chat is still gateway-owned.
  @ObservationIgnored private var gatewaySessions: [String: Set<String>] = [:]
  private(set) var toast: ToastMessage?
  /// Approval, sudo and secret requests waiting for an answer; the first one is on screen.
  private(set) var prompts: [ServerRequest] = []
  /// Stored ids of conversations with an unanswered request.
  private(set) var waitingOnYou: Set<String> = []

  private(set) var openChat: ChatModel?
  @ObservationIgnored private var chatCache: [String: ChatModel] = [:]
  /// Retained across screen visits, including a handoff still awaiting its acknowledgement.
  @ObservationIgnored private var chatQueues: [String: [String: ChatQueueState]] = [:]
  @ObservationIgnored private var liveToStored: [String: String] = [:]

  private let signIns: any SignInStore = AppModel.makeSignInStore()
  @ObservationIgnored private var signInSheet: SignInSheet?

  static func makeSignInStore() -> any SignInStore {
    #if DEBUG
      // UI tests and simulator screenshots: the tokens `scripts/sign-in.py` saved on the Mac.
      // `TALARIA_REMEMBER_SIGNIN_FILE=1` keeps the path for launches iOS makes itself (tapping a
      // notification after the app quit, in `NotificationTapTests`); `=0` forgets it.
      let environment = ProcessInfo.processInfo.environment
      let remembered = "debug.signInFile"
      switch environment["TALARIA_REMEMBER_SIGNIN_FILE"] {
      case "1": UserDefaults.standard.set(environment["TALARIA_SIGNIN_FILE"], forKey: remembered)
      case "0": UserDefaults.standard.removeObject(forKey: remembered)
      default: break
      }
      if let path = environment["TALARIA_SIGNIN_FILE"] ?? UserDefaults.standard.string(forKey: remembered),
        !path.isEmpty
      {
        return FileSignInStore(path: path)
      }
    #endif
    return KeychainSignInStore(service: "talaria.hermes-sign-in")
  }
  private var pump: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var activityTask: Task<Void, Never>?
  private var toastTask: Task<Void, Never>?
  private var isLoadingSessions = false
  /// A reload was asked for while one ran: that one may have read the list before the change
  /// the caller made, so run once more when it ends instead of dropping the request.
  @ObservationIgnored private var reloadAgain = false
  /// Chats archived here whose archive the Mac has not confirmed yet: a list read before it landed
  /// must not bring them back.
  @ObservationIgnored private var archiving: Set<String> = []

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
      phase = .needsSignIn
    case .noSignInConfigured:
      throw HermesError.noSignInConfigured
    }
  }

  /// Opens Hermes' sign-in sheet and, once it comes back, the chats.
  func signIn() async throws {
    guard let client, signInSheet == nil else { return }
    let sheet = SignInSheet()
    signInSheet = sheet
    defer { signInSheet = nil }
    try await sheet.run(http: client.http)
    enterReady()
  }

  /// Forgets the sign-in and returns to the sign-in screen. The address is kept for next time.
  func signOut() async {
    await PushCenter.shared.unregister()
    let old = client
    teardown()
    await old?.http.logout()
    // The old client's event stream ended with its pump, so the next sign-in gets a fresh one.
    client = endpoint.map { HermesClient(endpoint: $0, signIns: signIns) }
    phase = endpoint == nil ? .needsServer : .needsSignIn
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
    client = HermesClient(endpoint: endpoint, signIns: signIns)
  }

  private func teardown() {
    pump?.cancel()
    pump = nil
    reloadTask?.cancel()
    reloadTask = nil
    if let client { Task { await client.rpc.stop() } }
    client = nil
    path = []
    tab = .chats
    splitAgent = nil
    hubPath = []
    favoriteModels = []
    favoritesLoaded = false
    defaultCatalogs = [:]
    defaultCatalogErrors = [:]
    skillLists = [:]
    agentTotals = [:]
    headPreviews = [:]
    headPreviewStamps = [:]
    workingSince = [:]
    workingSnapshot = nil
    areas = AreaState()
    activityTask?.cancel()
    activityTask = nil
    openChat = nil
    chatCache = [:]
    chatQueues = [:]
    sessions = []
    liveStatuses = [:]
    gatewaySessions = [:]
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
    startActivityProbe()
    let push = PushCenter.shared
    push.app = self
    Task { await push.start(asking: Self.asksForNotifications) }
    push.openPending()
    #if DEBUG
      // UI tests open one conversation straight away: `TALARIA_OPEN_CHAT=<profile>/<stored id>`.
      if let target = ProcessInfo.processInfo.environment["TALARIA_OPEN_CHAT"], let slash = target.firstIndex(of: "/"),
        path.isEmpty
      {
        openChat(profile: String(target[..<slash]), storedID: String(target[target.index(after: slash)...]))
      }
    #endif
  }

  /// Whether to ask for notification permission on the first signed-in launch. Not in UI tests
  /// and simulator screenshots (the system alert would cover the screen), unless they ask for it.
  private static var asksForNotifications: Bool {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["TALARIA_PUSH_PROMPT"] == "1" { return true }
      if !(environment["TALARIA_SIGNIN_FILE"] ?? "").isEmpty { return false }
    #endif
    return true
  }

  /// Foreground: the socket has usually died while the phone slept.
  func becameActive() {
    guard phase == .ready, let client else { return }
    Task { await client.rpc.kick() }
    Task { await refreshSessions(quiet: true) }
    startActivityProbe()
    PushCenter.shared.becameActive()
  }

  /// Background: no polling while nobody is looking.
  func wentToBackground() {
    openChat?.wentToBackground()
    activityTask?.cancel()
    activityTask = nil
    // A turn that starts while the app is away would look as if it started on return.
    workingSnapshot = nil
    workingSince = [:]
    updateQuickActions()
  }

  // MARK: Turns other Hermes processes run

  /// The desktop app and terminals run chats in their own Hermes process, which sends this app no
  /// events. Their heartbeat lands in the shared session store, so look at the newest chats now
  /// and then while the app is open.
  private func startActivityProbe() {
    guard activityTask == nil else { return }
    activityTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        guard let self, !Task.isCancelled else { return }
        await self.probeActivity()
      }
    }
  }

  private func probeActivity() async {
    guard phase == .ready, let client, !isLoadingSessions, let recent = try? await client.recentActivity() else { return }
    var next = sessions
    var unknown = false
    for row in recent {
      guard let index = next.firstIndex(where: { $0.id == row.id }) else {
        unknown = true
        continue
      }
      next[index].lastActivity = row.lastActivity
      next[index].lastActivityAt = row.lastActivityAt
      next[index].lastActive = max(next[index].lastActive, row.lastActive)
    }
    if next != sessions {
      sessions = next
      families = SessionGrouping.families(next)
    }
    // A chat started elsewhere since the last full load.
    if unknown { scheduleReload() }
    if let chat = openChat, let row = next.first(where: { $0.id == chat.storedID }) { chat.rowChanged(row) }
    trackWorking()
  }

  /// A turn is running in this chat in a Hermes process this app's backend does not know about.
  /// `fresh` is a just-fetched row; the inbox copy is at most a few seconds old.
  func isRunningElsewhere(_ storedID: String, row fresh: SessionSummary? = nil) -> Bool {
    guard let row = fresh ?? row(storedID), row.isTurnRunning(now: Date().timeIntervalSince1970) else { return false }
    guard let roster = gatewaySessions[row.profile] else { return false }
    return !roster.contains(storedID)
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
          signIns.setSignIn(nil, for: source.endpoint)
          path = []
          phase = .needsSignIn
          show("Your session on the Mac ended. Sign in again.", kind: .info)
        }
      default:
        break
      }

    case .event(let event):
      if event.type == "prompt.settled", let id = event.payload["id"].scalarText {
        // A question answered or given up on anywhere (the desktop included) leaves every screen.
        requestWithdrawn(id)
        if let stored = liveToStored[event.sessionID], !prompts.contains(where: { $0.sessionID == event.sessionID }) {
          waitingOnYou.remove(stored)
        }
      }
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
    let profile = profile(forLive: request.sessionID)
    Task {
      if let result {
        await client.answer(request, result: result, profile: profile)
      } else {
        await client.decline(request, profile: profile)
      }
    }
  }

  /// The bot a live chat belongs to: the gateway routes a chat's calls by it.
  func profile(forLive liveID: String) -> String {
    if let chat = openChat, chat.liveID == liveID { return chat.profile }
    if let stored = liveToStored[liveID], let row = row(stored) { return row.profile }
    return chatCache.values.first { $0.liveID == liveID }?.profile ?? "default"
  }

  /// Every bot, by name: each is its own profile on the gateway, asked one by one. Bots seen in
  /// the inbox count too, for before the bot list has loaded.
  var profileNames: [String] {
    var names = Set(profiles.map(\.name))
    names.formUnion(sessions.map(\.profile))
    names.insert("default")
    return names.filter { !$0.isEmpty }.sorted()
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
    guard let client else { return }
    guard !isLoadingSessions else {
      reloadAgain = true
      return
    }
    isLoadingSessions = true
    defer {
      isLoadingSessions = false
      if reloadAgain {
        reloadAgain = false
        Task { await refreshSessions(quiet: true) }
      }
    }
    async let ownersJob = try? client.owners()
    let rosterProfiles = profileNames
    async let activeJob = try? client.activeSessions(profiles: rosterProfiles)
    async let totalsJob = sessionTotals(client)
    do {
      var rows = try await client.sessions()
      let totals = await totalsJob
      if !totals.isEmpty, totals != agentTotals { agentTotals = totals }
      rows += await topUpRows(client, loaded: rows)
      if !archiving.isEmpty { rows.removeAll { archiving.contains($0.id) } }
      let currentOwners = await ownersJob ?? owners
      if let active = await activeJob {
        setLiveStatuses(active, profiles: rosterProfiles)
      } else {
        invalidateLiveRoster(profiles: rosterProfiles)
      }
      if rows != sessions {
        sessions = rows
        families = SessionGrouping.families(rows)
      }
      setOwners(currentOwners)
      Task { await refreshChatOrigins(client) }
      sessionsError = nil
      hasLoadedSessions = true
      if let chat = openChat, let row = rows.first(where: { $0.id == chat.storedID }) { chat.rowChanged(row) }
      refreshRecentChats(from: rows)
      trackWorking()
      PushCenter.shared.reconcile { [unowned self] id in self.isWorking(id) || self.needsYou(id) }
    } catch HermesError.loginRequired {
      connection = .unauthorized
      if phase == .ready {
        path = []
        phase = .needsSignIn
      }
    } catch {
      _ = await ownersJob
      _ = await activeJob
      _ = await totalsJob
      sessionsError = error.localizedDescription
      hasLoadedSessions = true
      if !quiet { show("Could not load chats: \(error.localizedDescription)", kind: .failure) }
    }
  }

  func invalidateLiveRoster(profiles: [String]) {
    for profile in profiles { gatewaySessions[profile] = nil }
  }

  func refreshLiveRoster() async {
    guard let client else { return }
    let names = profileNames
    if let active = try? await client.activeSessions(profiles: names) {
      setLiveStatuses(active, profiles: names)
    } else {
      invalidateLiveRoster(profiles: names)
    }
  }

  func setLiveStatuses(_ active: [JSONValue], profiles: [String]) {
    for profile in profiles { gatewaySessions[profile] = [] }
    var fresh: [String: String] = [:]
    for entry in active {
      let key = entry["session_key"].stringValue
      if !key.isEmpty { gatewaySessions[entry["profile"].stringValue, default: []].insert(key) }
      let status = entry["status"].stringValue.lowercased()
      guard !key.isEmpty, !status.isEmpty else { continue }
      // Several live copies of one chat: a working one wins over an idle one.
      if fresh[key] == nil || status == "working" || status == "waiting" { fresh[key] = status }
    }
    if fresh != liveStatuses { liveStatuses = fresh }
    // A running reply may not announce its end to this socket (another client started it):
    // look again shortly while anything is working, so "Working" does not linger.
    if fresh.values.contains(where: { $0 == "working" || $0 == "waiting" }) { scheduleReload(after: 4) }
    trackWorking()
  }

  // MARK: Bots in the inbox

  /// Every bot's conversation count, read in parallel. A bot whose count fails is left out.
  private func sessionTotals(_ client: HermesClient) async -> [String: Int] {
    let names = profiles.map(\.name)
    return await withTaskGroup(of: (String, Int?).self) { group in
      for name in names { group.addTask { (name, try? await client.sessionCount(profile: name)) } }
      var out: [String: Int] = [:]
      for await (name, count) in group { if let count { out[name] = count } }
      return out
    }
  }

  /// The inbox load caps rows across all bots, so a quiet bot can be missing from it. Fetch the
  /// newest few of each bot that has fewer than a lead and its recent chats.
  private func topUpRows(_ client: HermesClient, loaded: [SessionSummary]) async -> [SessionSummary] {
    let wanted = AgentGrouping.maxRecent + 1
    let counts = Dictionary(grouping: loaded, by: \.profile).mapValues(\.count)
    let short = profiles.map(\.name).filter { name in
      let have = counts[name] ?? 0
      return have < wanted && have < (agentTotals[name] ?? wanted)
    }
    guard !short.isEmpty else { return [] }
    let known = Set(loaded.map(\.id))
    let fetched = await withTaskGroup(of: [SessionSummary].self) { group in
      for name in short { group.addTask { (try? await client.sessions(profile: name, limit: wanted)) ?? [] } }
      var out: [SessionSummary] = []
      for await rows in group { out += rows }
      return out
    }
    var seen = known
    return fetched.filter { seen.insert($0.id).inserted }
  }

  /// The inbox grouped by bot.
  func agentGroups(query: String) -> [AgentGroup] {
    var titles: [String: String] = [:]
    for profile in profiles { titles[profile.name] = profile.title }
    titles["default"] = titles["default"] ?? title(forProfile: "default")
    var live = workingIDs()
    live.formUnion(waitingOnYou)
    live.formUnion(liveStatuses.filter { $0.value == "waiting" }.map(\.key))
    let filter = originFilter
    let shown = filter == .all ? sessions : sessions.filter { filter.includes(origin(of: $0).origin) }
    // Totals count every chat on the Mac, so under a filter "N more" counts only loaded matches.
    return AgentGrouping.groups(
      sessions: shown, profiles: filter == .all ? orderedProfileNames : [], families: families,
      totals: filter == .all ? agentTotals : [:],
      titles: titles, query: query, isLive: { live.contains($0) }, now: Date().timeIntervalSince1970)
  }

  // MARK: Chat origins

  var originFilter: ChatOriginFilter {
    get { ChatOriginFilter(storage: preferences.originFilter) }
    set { preferences.originFilter = newValue.storage }
  }

  func origin(of session: SessionSummary) -> ChatOriginTag {
    chatOrigins.tag(for: session, startedHere: preferences.startedHere)
  }

  /// How many loaded chats (one per conversation) each filter would show.
  func originCounts() -> [ChatOriginFilter: Int] {
    let rows = SessionGrouping.collapse(sessions, families: families)
    var counts: [ChatOriginFilter: Int] = [:]
    for filter in ChatOriginFilter.menu {
      counts[filter] = filter == .all ? rows.count : rows.filter { filter.includes(origin(of: $0).origin) }.count
    }
    return counts
  }

  /// Reads the Mac's origins file at most once a minute (the Mac rewrites it every five).
  func refreshChatOrigins(_ client: HermesClient, force: Bool = false) async {
    if !force, let last = chatOriginsReadAt, Date().timeIntervalSince(last) < 60 { return }
    chatOriginsReadAt = Date()
    guard let map = try? await client.chatOrigins(), !map.tags.isEmpty else { return }
    if map != chatOrigins { chatOrigins = map }
  }

  /// Every chat with a reply running now: the same rule as `isWorking`, for all rows at once.
  private func workingIDs() -> Set<String> {
    let now = Date().timeIntervalSince1970
    var ids = Set(liveStatuses.filter { $0.value == "working" }.map(\.key))
    for session in sessions where session.isTurnRunning(now: now) { ids.insert(session.id) }
    if let chat = openChat, chat.activity != nil { ids.insert(chat.storedID) }
    return ids
  }

  /// Ties in the inbox break with the default bot first, then by name.
  private var orderedProfileNames: [String] {
    profiles.sorted { a, b in
      if a.isDefault != b.isDefault { return a.isDefault }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }.map(\.name)
  }

  /// A question or approval from this chat is waiting for an answer.
  func needsYou(_ storedID: String) -> Bool {
    waitingOnYou.contains(storedID) || liveStatuses[storedID] == "waiting"
  }

  /// Shows every conversation of a bot.
  func showAgent(_ profile: String) {
    if usesSplitLayout {
      splitAgent = profile
    } else {
      path.append(.agent(profile: profile))
    }
  }

  /// Loads the latest reply of each lead conversation that changed since it was last read.
  func loadHeadPreviews(_ heads: [SessionSummary]) async {
    guard let client else { return }
    let stale = heads.filter { headPreviewStamps[$0.id] != $0.recency }
    guard !stale.isEmpty else { return }
    for head in stale { headPreviewStamps[head.id] = head.recency }
    let found = await withTaskGroup(of: (String, String?).self) { group in
      for head in stale {
        group.addTask {
          // A busy turn's newest rows are often all tool calls; 16 usually reaches a reply, and
          // one wider read covers a long run of calls.
          var text: String?
          for limit in [16, 48] where text == nil {
            guard let rows = try? await client.latestMessages(storedID: head.id, profile: head.profile, limit: limit) else { break }
            text = PreviewText.lastReply(fromStoredRows: rows)
            if rows.count < limit { break }
          }
          return (head.id, text)
        }
      }
      var out: [String: String] = [:]
      for await (id, text) in group { if let text { out[id] = text } }
      return out
    }
    for (id, text) in found where headPreviews[id] != text { headPreviews[id] = text }
  }

  /// When the running turn in this chat began, if known.
  func workingStart(_ storedID: String) -> Double? {
    if let chat = openChat, chat.storedID == storedID, let start = chat.turnStartedAt { return start }
    return workingSince[storedID]
  }

  /// Notes chats that went from idle to working since the last look, for "Working 3m".
  private func trackWorking() {
    let now = Date().timeIntervalSince1970
    let current = workingIDs()
    if let previous = workingSnapshot {
      for id in current.subtracting(previous) where workingSince[id] == nil { workingSince[id] = now }
    }
    for id in workingSince.keys where !current.contains(id) { workingSince[id] = nil }
    workingSnapshot = current
  }

  /// A reply is running in this chat right now, as the backend or the open chat reports it.
  func isWorking(_ storedID: String) -> Bool {
    if let chat = openChat, chat.storedID == storedID, chat.activity != nil { return true }
    if liveStatuses[storedID] == "working" { return true }
    // Running in another Hermes process (the desktop app, a terminal): its heartbeat says so.
    return row(storedID)?.isTurnRunning(now: Date().timeIntervalSince1970) == true
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

  func refreshProfilesNow() async {
    await refreshProfiles()
  }

  private func refreshProfiles() async {
    guard let client, let list = try? await client.profiles() else { return }
    let added = Set(list.map(\.name)) != Set(profiles.map(\.name))
    let renamed = list.map(\.title) != profiles.map(\.title)
    profiles = list
    updateQuickActions()
    // Pushes name the bot: the Mac learns the names with the registration.
    if added || renamed { PushCenter.shared.settingsChanged() }
    // Counts and the per-bot top-up are read per bot, so a changed bot list needs a reload.
    if added { scheduleReload(after: 0.3) }
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
    if macHome.isEmpty, let home = try? await client.macHome(), !home.isEmpty { macHome = home }
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
    archiving.insert(session.id)
    forgetRecentChat(session.id)
    sessions.removeAll { $0.id == session.id }
    families = SessionGrouping.families(sessions)
    mutate(session, failure: "Could not archive the chat") { client in
      try await client.update(session, archived: true)
    } done: { [weak self] landed in
      // A list read that began before the archive landed can still finish after it: keep hiding
      // the chat a while (the Mac's own list leaves it out from now on).
      Task { @MainActor [weak self] in
        if landed { try? await Task.sleep(for: .seconds(30)) }
        self?.archiving.remove(session.id)
      }
    }
  }

  private func mutate(
    _ session: SessionSummary, failure: String, _ work: @escaping @MainActor (HermesClient) async throws -> Void,
    done: (@MainActor (_ landed: Bool) -> Void)? = nil
  ) {
    guard let client else { return }
    Task {
      do {
        try await work(client)
        done?(true)
      } catch {
        done?(false)
        show("\(failure): \(error.localizedDescription)", kind: .failure)
      }
      await refreshSessions(quiet: true)
    }
  }

  // MARK: Chats

  func queueState(profile: String, storedID: String) -> ChatQueueState {
    if let state = chatQueues[profile]?[storedID] { return state }
    let state = ChatQueueState()
    chatQueues[profile, default: [:]][storedID] = state
    return state
  }

  /// The model for a route. Models made ahead of navigation (a new chat, a new version) are
  /// handed over from the cache; anything else is built from the sidebar row.
  func chat(profile: String, storedID: String) -> ChatModel {
    if let cached = chatCache[storedID] { return cached }
    let model = ChatModel(app: self, profile: profile, storedID: storedID, row: row(storedID), live: nil)
    chatCache[storedID] = model
    return model
  }

  func open(_ session: SessionSummary) {
    // A row from a bot's full list may be older than the inbox load; the chat needs its
    // source to know whether it can reply.
    if row(session.id) == nil {
      sessions.append(session)
      families = SessionGrouping.families(sessions)
    }
    show(.chat(profile: session.profile, storedID: session.id))
  }

  /// Opens a chat from any area (a bot's page, a cron run, a kanban card) in the Chats area.
  func openChat(profile: String, storedID: String) {
    let route = Route.chat(profile: profile, storedID: storedID)
    // On iPhone, Kanban lives on the Chats stack: a card's run opens over it, and back returns.
    // The agent hub has its own stack, and a chat opened from its pages stacks there.
    if tab == .chats, !usesSplitLayout {
      path.append(route)
    } else if tab == .bots, !usesSplitLayout {
      hubPath.append(.chat(profile: profile, storedID: storedID))
    } else {
      tab = .chats
      path = [route]
    }
  }

  /// Opens an area that has no dock item: a page on the Chats stack, or the list column in the split view.
  func openArea(_ area: AppTab) {
    if area == .cron { areas.cronProfile = nil }
    guard !usesSplitLayout, let route = Route.area(area) else {
      tab = area
      return
    }
    tab = .chats
    path.append(route)
  }

  /// The stored id of the chat on screen, for marking it in the inbox on iPad.
  var selectedStoredID: String? {
    guard case .chat(_, let storedID)? = path.last else { return nil }
    return storedID
  }

  private func show(_ route: Route) {
    if usesSplitLayout {
      path = [route]
    } else if tab == .bots, case .chat(let profile, let storedID) = route {
      hubPath.append(.chat(profile: profile, storedID: storedID))
    } else {
      path.append(route)
    }
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
      updateQuickActions()
      preferences.noteStartedHere(live.storedID)
      chatCache[live.storedID] = ChatModel(app: self, profile: profile, storedID: live.storedID, row: nil, live: live)
      // From the agent hub on iPhone the chat stacks over the hub; anywhere else it opens in Chats.
      if tab != .bots || usesSplitLayout { tab = .chats }
      show(.chat(profile: profile, storedID: live.storedID))
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
    if tab == .bots, !usesSplitLayout, let last = hubPath.indices.last, case .chat = hubPath[last] {
      hubPath[last] = .chat(profile: profile, storedID: storedID)
      return
    }
    if let last = path.indices.last {
      path[last] = route
    } else {
      path.append(route)
    }
  }

  /// Makes a model for a chat that was created elsewhere (a bot's standing chat) and opens it.
  func openPrepared(_ live: LiveSession, profile: String) {
    chatCache[live.storedID] = ChatModel(app: self, profile: profile, storedID: live.storedID, row: nil, live: live)
    openChat(profile: profile, storedID: live.storedID)
  }

  func chatAppeared(_ chat: ChatModel) {
    openChat = chat
    PushCenter.shared.chatOpened(storedID: chat.storedID)
    recordOpened(chat)
  }

  func chatDisappeared(_ chat: ChatModel) {
    chat.leave()
    if openChat === chat { openChat = nil }
    for (key, cached) in chatCache where cached === chat { chatCache[key] = nil }
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
