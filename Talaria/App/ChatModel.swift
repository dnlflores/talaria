import HermesKit
import Observation
import SwiftUI
import UIKit

/// Something picked in the composer, waiting to go out with the next message.
struct ComposerAttachment: Identifiable {
  enum Kind { case image, file }
  enum Status: Equatable { case preparing, ready, failed(String) }

  let id = UUID()
  var kind: Kind
  var name: String
  var mimeType = "application/octet-stream"
  var data: Data?
  var thumbnail: UIImage?
  var status: Status = .preparing

  var isUsable: Bool {
    if case .failed = status { return false }
    return true
  }
}

/// One open conversation: its transcript, its live session on the Mac, and the composer.
///
/// Chats run in the Hermes gateway on the Mac, the process the desktop app runs them in, so a
/// chat open in both is one live chat: each app sees the other's turns, thinking and questions as
/// they happen, and either can answer a question. Two rules shape the rest:
/// - A chat another Hermes process holds (a terminal running its own agent) is shown read-only
///   and kept fresh by polling; sending continues it as a new version (a branch).
/// - A dropped socket loses its attachment to every chat. On return the chat re-attaches and folds
///   the fresh transcript into what is on screen without rebuilding it.
@MainActor @Observable
final class ChatModel: Identifiable {
  let profile: String
  private(set) var storedID: String
  private(set) var liveID: String?
  /// This app's attachment to the chat on the gateway, let go when the chat closes.
  @ObservationIgnored private var subscriptionID = ""
  let section: SessionSection

  private(set) var state = ChatState() {
    didSet {
      layOut()
      if state.isStreaming != oldValue.isStreaming { streamingChanged() }
    }
  }
  private(set) var rows: [TranscriptRow] = []
  @ObservationIgnored private var fileCache: [String: [FileReference]] = [:]
  private(set) var isLoading = true
  private(set) var loadError: String?
  /// The transcript could be read but the session could not be attached.
  private(set) var isReadOnly = false
  /// Another Hermes process that has this chat open right now.
  private(set) var owner: ChatOwner?
  /// That other process is running a turn here right now (its heartbeat says so). No events
  /// reach this app for it, so the transcript is polled and the activity read from it.
  private(set) var isRunningElsewhere = false {
    didSet { if isRunningElsewhere != oldValue { layOut() } }
  }
  private(set) var isSending = false
  private(set) var isBranching = false
  private(set) var uploadStatus = ""
  private(set) var catalog: [ModelProvider]?
  private(set) var catalogError: String?
  /// Older messages are on the Mac beyond what is on screen; they load as the transcript scrolls up.
  private(set) var hasOlder = false
  private(set) var isLoadingOlder = false
  /// Bumped when the view should scroll to the newest message.
  private(set) var scrollToEnd = 0

  var draft: String { didSet { app?.preferences.setDraft(draft, for: storedID) } }
  var attachments: [ComposerAttachment] = []
  var sendWhenReady = false
  /// Messages written while a reply runs. They go out one per turn once it ends, or now on request.
  private(set) var queue = PromptQueue<ComposerAttachment>()

  private weak var app: AppModel?
  private var prepared: LiveSession?
  private var hasOpened = false
  private var isClosed = false
  private var hasSpoken = false
  private var isWatching = false
  private var watchTask: Task<Void, Never>?
  private var reattachTask: Task<Void, any Error>?
  private var ownerHoldUntil = Date.distantPast
  private var preferredModel = ""
  private var preferredProvider = ""
  private var preferredEffort = ""
  /// Last time the gateway said anything about this chat's turn.
  @ObservationIgnored private var lastEventAt = Date()
  @ObservationIgnored private var livenessTask: Task<Void, Never>?
  /// The part of the stored history on screen, and where the next older page starts.
  @ObservationIgnored private var window = HistoryWindow.complete
  /// Bumped whenever `window` changes outside `loadOlder`, so a page read for an older window is dropped.
  @ObservationIgnored private var windowGeneration = 0

  /// Rows read when a chat opens and on each look for news, and per older page while scrolling up.
  /// A long agentic turn runs to a hundred rows and more, most of them tool output.
  static let newestPageRows = 60
  static let olderPageRows = 100
  /// An idle chat whose newest turn is longer than this opens part way into that turn.
  static let openingRowCap = 400

  init(app: AppModel, profile: String, storedID: String, row: SessionSummary?, live: LiveSession?) {
    self.app = app
    self.profile = profile
    self.storedID = storedID
    section = row?.section ?? .chats
    prepared = live
    draft = app.preferences.draft(for: storedID)
    state.title = row?.title ?? ""
    state.info.model = row?.model ?? ""
    state.info.provider = row?.provider ?? ""
    state.info.cwd = row?.cwd ?? ""
    state.info.branch = row?.gitBranch ?? ""
    owner = app.owners[storedID]
  }

  #if DEBUG
  /// Offline UI-test data rendered by the real transcript, without attaching to a live chat.
  static func scrollPreview(app: AppModel, short: Bool) -> ChatModel {
    let chat = ChatModel(app: app, profile: "preview", storedID: "scroll-preview", row: nil, live: nil)
    chat.state.title = "Scroll preview"
    if !short {
      for turn in 1...8 {
        chat.state.items.append(.user("Earlier question \(turn)", timestamp: Double(turn)))
        let lines = (1...14).map { "Earlier reply \(turn), line \($0)." }.joined(separator: "\n\n")
        chat.state.items.append(TranscriptItem(kind: .assistant, text: lines))
      }
    }
    chat.state.items.append(.user("Inspect the latest change.", timestamp: 20))
    chat.state.items.append(.tool(ToolCall(callID: "scroll-preview-tool", name: "read_file", isDone: true)))
    chat.state.items.append(TranscriptItem(kind: .assistant, text: "Latest reply. Everything is up to date."))
    chat.isLoading = false
    return chat
  }
  #endif

  private var client: HermesClient? { app?.client }

  /// A turn run elsewhere is laid out as live too: its work log counts tools so far, and its
  /// files wait for the answer.
  private func layOut() {
    rows = TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming || isRunningElsewhere, fileCache: &fileCache)
  }
  private var now: Double { Date().timeIntervalSince1970 }

  // MARK: Derived

  var isChannel: Bool { section.isChannel }
  /// Sending from here cannot reach this conversation itself; it starts a new version instead.
  var continuesAsNewVersion: Bool { owner != nil || isChannel }
  var title: String {
    let base = SessionSummary.baseTitle(state.title)
    return base.isEmpty ? "New chat" : base
  }
  var isStreaming: Bool { state.isStreaming }
  var status: String { state.status }
  /// What the running turn is doing, in words for the transcript and the title bar.
  var activity: TurnActivity? {
    guard let activity = state.activity else {
      return isRunningElsewhere ? TurnActivity.inferred(from: state.items) : nil
    }
    if let liveID, app?.prompts.contains(where: { $0.sessionID == liveID }) == true { return .waiting }
    return activity
  }
  var turnStartedAt: Double? {
    state.turnStartedAt ?? (isRunningElsewhere ? TurnActivity.turnStart(in: state.items) : nil)
  }
  /// Every file the finished turns wrote, edited or delivered, once each.
  var files: [FileReference] {
    var seen = Set<String>()
    var out: [FileReference] = []
    for row in rows {
      guard case .files(let turn) = row else { continue }
      for file in turn.files where seen.insert(file.path).inserted { out.append(file) }
    }
    return out
  }
  var info: SessionInfo { state.info }
  /// A reply is running or a message is on its way, so what is sent now waits in the queue.
  var isBusy: Bool { state.isStreaming || isSending }
  /// Sending now would queue the message rather than start a turn.
  var sendQueues: Bool { isBusy && !continuesAsNewVersion }
  var canSend: Bool {
    guard !isReadOnly, !isBranching else { return false }
    // A photo still being shrunk has no bytes yet; it is ready in a moment.
    if attachments.contains(where: { $0.status == .preparing }) { return false }
    return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains { $0.isUsable }
  }
  var showsStop: Bool { state.isStreaming && !continuesAsNewVersion && !canSend }
  var isEmpty: Bool { rows.isEmpty && !isLoading }

  // MARK: Opening

  func open() async {
    guard !hasOpened else { return }
    hasOpened = true
    guard let client else { return }

    if let live = prepared {
      prepared = nil
      // A new chat, or a copy that brought its whole history along.
      adopt(live, history: .replace(TranscriptItem.items(fromHistory: live.messages), .complete))
      isLoading = false
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
      return
    }

    // Ask who has it open right before deciding how to open it.
    async let freshRow = try? client.session(storedID: storedID, profile: profile)
    async let freshActive = try? client.activeSessions(profiles: (app?.profileNames ?? []) + [profile])
    if let owners = await app?.refreshOwners() { owner = owners[storedID] }
    let row = await freshRow
    // Our own backend running it is not "elsewhere": decide on a fresh live list, not the inbox's.
    if let active = await freshActive { app?.setLiveStatuses(active) }
    if isClosed { return }
    // The desktop app runs chats in its own backend, which holds no lease this app can see:
    // a turn running there is only visible as a heartbeat. Watch it like an owned chat.
    if owner == nil, !isChannel, let other = elsewhereOwner(row: row) {
      owner = other
      isRunningElsewhere = true
    }
    if continuesAsNewVersion {
      await openWatching()
      return
    }
    // The session comes back without its transcript (a long chat's runs to megabytes); the newest
    // page of stored history is read alongside it, and older pages as the transcript scrolls up.
    let newest = Task { try await self.readNewest(client: client, toTurnStart: false) }
    do {
      try await client.rpc.waitUntilReady(timeout: 45)
      let live = try await client.resume(storedID: storedID, profile: profile, omitMessages: true)
      var history = try await newest.value
      if isClosed { return }
      if live.isRunning, history.window.hasOlder, !history.items.contains(where: { $0.kind == .user }) {
        // A running turn longer than an idle chat opens on: its start is needed to place it.
        history = try await readNewest(client: client, toTurnStart: true)
        if isClosed { return }
      }
      adopt(live, history: .replace(history.items, history.window))
      isLoading = false
      if let row = app?.row(storedID), row.unread { app?.setUnread(row, false) }
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
    } catch {
      if isClosed { return }
      loadError = error.localizedDescription
      if let history = try? await newest.value {
        state.items = history.items
        setWindow(history.window)
        isReadOnly = true
      }
      isLoading = false
    }
  }

  /// Stored history to put on screen with a live session.
  private enum History {
    /// Start the transcript over with these items.
    case replace([TranscriptItem], HistoryWindow)
    /// Fold the newest page into what is on screen; `items` and `window` are the page on its own,
    /// for when it does not line up.
    case newest(page: [JSONValue], items: [TranscriptItem], window: HistoryWindow)

    var items: [TranscriptItem] {
      switch self {
      case .replace(let items, _), .newest(_, let items, _): return items
      }
    }
  }

  private func adopt(_ live: LiveSession, history: History) {
    liveID = live.liveID
    subscriptionID = live.subscriptionID
    app?.noteLive(live.liveID, storedID: storedID)
    var next = state
    next.info.merge(live.info)
    if next.title.isEmpty { next.title = next.info.title }
    var fresh = history.items
    // The gateway does not say when a running turn started; for the timer, its message (stored when it
    // was sent) does.
    let turnStartedAt = live.turnStartedAt ?? (live.isRunning ? TurnActivity.turnStart(in: fresh) : nil)
    if !queue.onMac.isEmpty {
      let texts = queue.onMac.map(\.text)
      let running = ChatState.normalized(live.inflight["user"].stringValue)
      if live.isRunning, !running.isEmpty, texts.contains(where: { running.contains(ChatState.normalized($0)) }) {
        // The reply running now is theirs: the history already holds them in place.
        _ = queue.takeOnMac()
      } else if live.isRunning {
        // Still waiting behind the running reply: the Mac's early copies stay out of the transcript.
        fresh = TranscriptItem.withoutEarlyQueued(
          fresh, queued: texts, runningUser: live.inflight["user"].string, turnStartedAt: live.turnStartedAt)
      } else {
        // The Mac ran them while the phone was away, or dropped them (a stopped reply clears its
        // queue). What is not in the transcript comes back to the phone's queue, held.
        var check = ChatState()
        check.items = fresh
        let handed = queue.takeOnMac()
        queue.returnFromMac(handed.filter { !check.hasUserMessage($0.text) })
      }
    }
    switch history {
    case .replace(_, let newWindow):
      next.items = fresh
      next.applyInflight(live.inflight, turnStartedAt: live.turnStartedAt, now: now)
      setWindow(newWindow)
    case .newest(let page, _, let pageWindow):
      fold(newest: page, items: fresh, pageWindow: pageWindow, into: &next, inflight: live.inflight, turnStartedAt: live.turnStartedAt)
    }
    next.applyLiveStatus(isRunning: live.isRunning, startedAt: turnStartedAt, now: now)
    state = next
    lastEventAt = Date()
    for request in live.openRequests { app?.deliver(request) }
  }

  // MARK: Stored history, a page at a time

  /// The newest stored history: the newest page, read on back to where the newest turn starts
  /// (`toTurnStart`), else no further than `openingRowCap` rows. It starts where a turn starts
  /// when one was read, so no turn is shown in part.
  private func readNewest(client: HermesClient, toTurnStart: Bool) async throws -> (items: [TranscriptItem], window: HistoryWindow) {
    var window = HistoryWindow()
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: Self.newestPageRows, nextLimit: Self.olderPageRows, wholeTurns: true,
      fetch: { [storedID, profile] offset, limit in
        try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
      },
      until: { rows in
        TranscriptItem.items(fromStoredRows: rows).contains { $0.kind == .user } || (!toTurnStart && rows.count >= Self.openingRowCap)
      })
    return (TranscriptItem.items(fromStoredRows: rows), window)
  }

  /// The newest page alone, to fold into what is on screen: the raw page, its items, and a window
  /// of just that page for when it does not line up.
  private func readNewestPage(client: HermesClient) async throws -> History {
    var window = HistoryWindow()
    var newestPage: [JSONValue] = []
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: Self.newestPageRows, nextLimit: Self.olderPageRows,
      fetch: { [storedID, profile] offset, limit in
        let page = try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
        if offset == 0 { newestPage = page }
        return page
      },
      until: { _ in true })
    return .newest(page: newestPage, items: TranscriptItem.items(fromStoredRows: rows), window: window)
  }

  /// Folds the newest page into `next`: on the end of what is held when it lines up, else in
  /// place of it (then older pages read again from there as the transcript scrolls up).
  private func fold(
    newest page: [JSONValue], items fresh: [TranscriptItem], pageWindow: HistoryWindow, into next: inout ChatState,
    inflight: JSONValue, turnStartedAt: Double?
  ) {
    let unnamed = window.reachedStart && !window.overlaps(newest: page) && window == HistoryWindow.complete
    if window.overlaps(newest: page) || unnamed,
      next.reconcileTail(fresh: fresh, inflight: inflight, turnStartedAt: turnStartedAt, now: now)
    {
      var updated = window
      if unnamed { updated.identify(newest: page) } else { updated.absorb(newest: page) }
      setWindow(updated)
    } else {
      next.replace(with: fresh, inflight: inflight, turnStartedAt: turnStartedAt, now: now)
      setWindow(pageWindow)
    }
  }

  private func setWindow(_ new: HistoryWindow) {
    window = new
    windowGeneration += 1
    if hasOlder != new.hasOlder { hasOlder = new.hasOlder }
  }

  /// Reads the next older page and puts it above what is on screen. The transcript calls this as
  /// it is scrolled near the top, and passes `untilStill` so the page lands once the scrolling
  /// stops: moving the content back into place mid-fling would cut the fling short.
  func loadOlder(untilStill: () async -> Void = {}) async {
    guard hasOlder, !isLoadingOlder, !isLoading, !isClosed, let client else { return }
    isLoadingOlder = true
    defer { isLoadingOlder = false }
    let generation = windowGeneration
    var older = window
    do {
      let rows = try await HistoryWindow.readOlder(
        into: &older, firstLimit: Self.olderPageRows, nextLimit: Self.olderPageRows, wholeTurns: true,
        fetch: { [storedID, profile] offset, limit in
          #if DEBUG
            // UI tests stand in for a slow connection: `TALARIA_UITEST_PAGE_DELAY=<seconds>`.
            if let delay = ProcessInfo.processInfo.environment["TALARIA_UITEST_PAGE_DELAY"].flatMap(Double.init) {
              try await Task.sleep(for: .seconds(delay))
            }
          #endif
          return try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
        },
        until: { $0.contains(where: HistoryWindow.startsTurn) })
      await untilStill()
      // The transcript was replaced meanwhile: this page belongs to the old one.
      guard generation == windowGeneration, !isClosed else { return }
      setWindow(older)
      let items = TranscriptItem.items(fromStoredRows: rows)
      guard !items.isEmpty else { return }
      var next = state
      next.items.insert(contentsOf: items, at: 0)
      state = next
    } catch {
      if !isClosed { app?.show("Could not load earlier messages: \(error.localizedDescription)", kind: .failure) }
    }
  }

  // MARK: Chats this app cannot drive right now

  private func openWatching() async {
    isWatching = true
    do {
      try await refreshWatched(first: true)
    } catch {
      loadError = error.localizedDescription
    }
    if isClosed { return }
    isLoading = false
    startWatching()
  }

  private func refreshWatched(first: Bool = false) async throws {
    guard let client else { return }
    if first || state.items.isEmpty {
      let history = try await readNewest(client: client, toTurnStart: isRunningElsewhere)
      if isClosed { return }
      state.items = history.items
      setWindow(history.window)
      return
    }
    // Only the newest page: polling a long chat must not read all of it every few seconds.
    guard case .newest(let page, let fresh, let pageWindow) = try await readNewestPage(client: client), !isClosed else { return }
    var next = state
    fold(newest: page, items: fresh, pageWindow: pageWindow, into: &next, inflight: nil, turnStartedAt: nil)
    if next != state { state = next }
  }

  private func startWatching() {
    watchTask?.cancel()
    watchTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.isClosed else { return }
        try? await Task.sleep(for: .seconds(self.owner != nil ? 3.5 : 8))
        if Task.isCancelled || self.isClosed { return }
        if self.isBranching { continue }
        let owners = await self.app?.refreshOwners() ?? [:]
        var current = owners[self.storedID]
        if current == nil, !self.isChannel {
          if let row = try? await self.client?.session(storedID: self.storedID, profile: self.profile) {
            current = self.elsewhereOwner(row: row)
            self.isRunningElsewhere = current != nil
          } else if self.isRunningElsewhere {
            current = self.owner
          }
        } else {
          self.isRunningElsewhere = false
        }
        if Task.isCancelled || self.isClosed { return }
        if self.owner != nil, current == nil, !self.isChannel, Date() > self.ownerHoldUntil {
          await self.goLive()
          return
        }
        if current != nil || self.isChannel { self.owner = current }
        try? await self.refreshWatched()
      }
    }
  }

  /// A stand-in owner for a turn another Hermes process is running here, or nil.
  private func elsewhereOwner(row: SessionSummary?) -> ChatOwner? {
    guard let app, app.isRunningElsewhere(storedID, row: row) else { return nil }
    return ChatOwner(sessionID: storedID, surface: (row ?? app.row(storedID))?.createdSource ?? "")
  }

  /// The other process let go: drop any stale copy our backend still holds, then resume for real.
  private func goLive() async {
    watchTask = nil
    owner = nil
    isRunningElsewhere = false
    isWatching = false
    isReadOnly = false
    await dropLive()
    do {
      try await reattach()
    } catch {
      if !isClosed { app?.show("Could not reopen the chat: \(error.localizedDescription)", kind: .failure) }
    }
  }

  /// Forgets the attachment; the next send or reattach resumes the chat afresh.
  private func dropLive() async {
    liveID = nil
  }

  private func markOwned(by other: ChatOwner, holdSeconds: Double = 0) {
    guard !isClosed else { return }
    let wasOwned = owner != nil
    owner = other
    isWatching = true
    if holdSeconds > 0 { ownerHoldUntil = Date().addingTimeInterval(holdSeconds) }
    if !wasOwned { Task { await dropLive() } }
    var next = state
    next.isStreaming = false
    next.status = ""
    state = next
    startWatching()
  }

  /// Called when the app's owner map changes: the Mac may have just opened this chat.
  func ownersChanged() {
    guard !isClosed, !isLoading, !isWatching, !state.isStreaming, !isSending, let other = app?.owners[storedID] else { return }
    markOwned(by: other)
  }

  private func refused(message: String, text: String) async {
    let owners = await app?.refreshOwners() ?? [:]
    let surface = message.firstMatch(of: /(?i)opened by ([\w-]+)/).map { String($0.1) } ?? "desktop"
    markOwned(by: owners[storedID] ?? ChatOwner(sessionID: storedID, surface: surface), holdSeconds: 15)
    if !text.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
  }

  /// Copies the whole history into a conversation this app owns and moves the composer there.
  private func continueAsNewVersion(send: Bool) async {
    guard !isBranching, let client, let app else { return }
    isBranching = true
    defer { isBranching = false }
    do {
      try await client.rpc.waitUntilReady(timeout: 45)
      let row = app.row(storedID)
      let live = try await client.branch(
        storedID: storedID, profile: profile, cwd: state.info.cwd.isEmpty ? row?.cwd ?? "" : state.info.cwd,
        model: state.info.model.isEmpty ? row?.model ?? "" : state.info.model,
        provider: state.info.provider.isEmpty ? row?.provider ?? "" : state.info.provider)
      // The words moved to the new version: do not leave them behind in the original.
      let words = draft
      let picked = attachments
      draft = ""
      attachments = []
      let model = ChatModel(app: app, profile: profile, storedID: live.storedID, row: nil, live: live)
      model.state.title = state.title
      model.attachments = picked
      model.draft = words
      model.sendWhenReady = send && (!words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty)
      app.show(
        isChannel ? "Continuing as a Hermes chat. \(section.label) will not see it." : "Continuing here as a new version. The Mac keeps the original.",
        kind: .success, seconds: 4)
      app.replaceOpenChat(with: model)
      app.scheduleReload(after: 0.6)
    } catch {
      app.show("Could not continue here: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Staying attached

  func connectionReady() async {
    guard hasOpened, !isClosed, !isLoading, !isReadOnly, !isWatching else { return }
    try? await reattach()
  }

  func liveSessionReclaimed() async {
    liveID = nil
    guard !isClosed, !isLoading, !isReadOnly, !isWatching else { return }
    try? await reattach()
  }

  /// Re-binds this chat to a live backend session after a reconnect, a reclaim, or "session not found".
  private func reattach() async throws {
    if let running = reattachTask {
      try await running.value
      return
    }
    let task = Task { [weak self] in
      guard let self, let client = self.client else { return }
      // A never-spoken chat has no stored row. A plain resume of one that was reaped materializes
      // the row with the backend's process-wide model instead of the bot's, which that bot's provider
      // may reject. `lazy` re-attaches a live one and otherwise answers 4007; then mint a clean session.
      let spoken = self.state.items.contains { !$0.isPending && !$0.isLocal }
      var live: LiveSession
      do {
        live = try await client.resume(storedID: self.storedID, profile: self.profile, lazy: !spoken, omitMessages: true)
      } catch {
        let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
        if self.isClosed || wrapped.isConnectionLoss || spoken { throw error }
        let options = NewSessionOptions(
          model: self.preferredModel, provider: self.preferredProvider, reasoningEffort: self.preferredEffort)
        live = try await client.create(profile: self.profile, options: options)
        let words = self.draft
        self.app?.preferences.setDraft("", for: self.storedID)
        self.storedID = live.storedID
        self.draft = words
      }
      if self.isClosed { return }
      // A chat minted just now has no stored history yet; what was typed in it stays.
      let history = spoken
        ? try await self.readNewestPage(client: client) : History.newest(page: [], items: [], window: .complete)
      if self.isClosed { return }
      self.adopt(live, history: history)
    }
    reattachTask = task
    defer { reattachTask = nil }
    try await task.value
  }

  /// Waits for a usable connection and live session. Phones send right as they wake up.
  private func ensureLive() async throws {
    guard let client else { throw HermesError.notConnected }
    let isOpen = await client.rpc.isOpen
    if !isOpen {
      await client.rpc.kick()
      try await client.rpc.waitUntilReady(timeout: 45)
    }
    if let running = reattachTask { _ = try? await running.value }
    if liveID == nil { try await reattach() }
    if liveID == nil { throw HermesError.notConnected }
  }

  // MARK: Events

  func handle(_ event: GatewayEvent) {
    lastEventAt = Date()
    var next = state
    // A turn the Mac starts on its own right after a reply ended is the one for the messages
    // handed to it while the phone slept.
    if event.type == "message.start", !next.isStreaming, !queue.onMac.isEmpty {
      next.beginHandedOverTurn(texts: queue.takeOnMac().map(\.text), now: now)
      scrollToEnd += 1
    }
    let effects = next.apply(event: event.type, payload: event.payload, now: now)
    state = next
    for effect in effects {
      switch effect {
      case .notice(let text): app?.show(text)
      case .failure(let text): app?.show(text, kind: .failure, seconds: 6)
      case .refused(let message, let text): Task { await refused(message: message, text: text) }
      case .sessionsChanged: app?.scheduleReload()
      case .requestCancelled(let id): app?.requestWithdrawn(id)
      case .turnFinished: UINotificationFeedbackGenerator().notificationOccurred(.success)
      }
    }
  }

  func rowChanged(_ row: SessionSummary) {
    // The stored title is the authority (a new version arrives untitled).
    if !row.title.isEmpty, row.title != state.title { state.title = row.title }
    // Another Hermes process started a turn here while this copy sat idle. Our own turns are
    // excluded: they stream events here, and the label is cleared within moments of the end.
    if !isClosed, !isLoading, !isWatching, !isChannel, !state.isStreaming, !isSending, !isBranching,
      Date().timeIntervalSince(lastEventAt) > 10, let other = elsewhereOwner(row: row)
    {
      isRunningElsewhere = true
      markOwned(by: other)
    }
  }

  // MARK: Staying truthful about a running turn

  /// While a turn runs, check now and then that it really is still running. A reply that
  /// finished while the socket was away never sends its end to us, and the screen would say
  /// "Working" forever.
  private func streamingChanged() {
    livenessTask?.cancel()
    livenessTask = nil
    guard state.isStreaming else {
      drainQueue()
      return
    }
    livenessTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self, !Task.isCancelled, !self.isClosed, self.state.isStreaming else { return }
        guard Date().timeIntervalSince(self.lastEventAt) > 20 else { continue }
        await self.confirmStillRunning()
      }
    }
  }

  private func confirmStillRunning() async {
    guard let client, let liveID, !isWatching else { return }
    guard let active = try? await client.activeSessions(profiles: [profile]) else { return }
    let entry = active.first { $0["id"].string == liveID }
    let status = entry?["status"].stringValue.lowercased() ?? ""
    if let entry, entry["status"].isNull || ["working", "waiting", "starting"].contains(status) { return }
    // Gone or idle: re-attach, which folds in the finished reply and takes `running` from the backend.
    lastEventAt = Date()
    try? await reattach()
  }

  // MARK: Questions

  func attach(clarify request: ServerRequest) {
    var next = state
    next.attach(clarify: request)
    state = next
    scrollToEnd += 1
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
  }

  /// `values[i]` holds the answers to question `i`, or `nil` to skip it.
  func answer(requestID: String, values: [[String]?]) {
    var next = state
    guard let outcome = next.answer(clarifyRequestID: requestID, values: values) else { return }
    state = next
    app?.clearWaiting(storedID: storedID)
    let profile = profile
    Task { await client?.answer(outcome.request, result: outcome.result, profile: profile) }
  }

  // MARK: Sending

  /// The composer's send. While a reply runs the message waits in the queue; otherwise it goes now.
  func send() async {
    guard !isReadOnly else { return }
    if continuesAsNewVersion {
      if canSend, !isSending { await continueAsNewVersion(send: true) }
      return
    }
    guard canSend else { return }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let picked = attachments.filter(\.isUsable)
    draft = ""
    attachments = []
    if isBusy {
      queue.enqueue(text: text, attachments: picked, now: now)
      return
    }
    await deliver(text: text, picked: picked, origin: .composer)
  }

  /// Where a message being delivered came from, which decides where it goes back if it fails.
  private enum Origin {
    case composer
    case queue(PromptQueue<ComposerAttachment>.Entry)
  }

  /// Starts a turn with this message: shows it as sending, uploads what was picked, submits.
  private func deliver(text: String, picked: [ComposerAttachment], origin: Origin) async {
    guard let client else { return }
    var item = TranscriptItem(kind: .user, text: text, timestamp: now)
    item.isPending = true
    item.attachments = picked.map { attachment in
      AttachmentChip(
        id: attachment.id, kind: attachment.kind == .image ? .image : .file, name: attachment.name,
        thumbnail: attachment.thumbnail?.jpegData(compressionQuality: 0.7))
    }
    let itemID = item.id
    state.items.append(item)
    scrollToEnd += 1
    isSending = true
    defer {
      isSending = false
      uploadStatus = ""
      drainQueue()
    }
    let fromQueue: Bool
    if case .queue = origin { fromQueue = true } else { fromQueue = false }

    do {
      var status = ""
      var attempt = 0
      while true {
        do {
          try await ensureLive()
          guard let liveID else { throw HermesError.notConnected }
          let staged = try await stage(picked, liveID: liveID, client: client)
          let full = ([text] + staged.references).filter { !$0.isEmpty }.joined(separator: "\n\n")
          update(itemID) { $0.sentText = full }
          state.beginTurn(now: now)
          // A queued message must never cut into a reply the Mac is still wrapping up.
          status = try await client.submit(
            liveID: liveID, profile: profile, text: full, queued: fromQueue, images: staged.images)
          break
        } catch {
          let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
          guard attempt < 2, wrapped.isSessionGone || wrapped.isConnectionLoss else { throw error }
          attempt += 1
          if wrapped.isSessionGone { liveID = nil }
          try? await Task.sleep(for: .milliseconds(400))
          if wrapped.isConnectionLoss {
            // The ack may have been lost with the socket: if the turn already landed, do not send it twice.
            try? await ensureLive()
            if state.items.first(where: { $0.id == itemID })?.hasLanded == true {
              status = "recovered"
              break
            }
          }
        }
      }
      let sentAt = now
      update(itemID) {
        $0.isPending = false
        $0.timestamp = sentAt
      }
      hasSpoken = true
      if status == "queued", !fromQueue { app?.show("Queued. It goes out after the current reply.") }
      if state.title.isEmpty { state.title = String((text.isEmpty ? picked.first?.name ?? "" : text).prefix(60)) }
      PushCenter.shared.noteSent(profile: profile, storedID: storedID, title: title)
      app?.scheduleReload(after: 2.5)
    } catch {
      state.isStreaming = false
      let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
      if wrapped.isOwnedElsewhere {
        // Open on the Mac: nothing was sent. Keep the words and the attachments, and explain.
        state.items.removeAll { $0.id == itemID }
        attachments = picked + attachments
        await refused(message: wrapped.localizedDescription, text: text)
        return
      }
      update(itemID) {
        $0.isPending = false
        $0.isFailed = true
      }
      switch origin {
      case .composer:
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
        attachments = picked + attachments
        app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure, seconds: 6)
      case .queue(let entry):
        // Back at the front of the queue, held until sent by hand, so nothing is retried in a loop.
        queue.restore(entry)
        queue.pause()
        app?.show("Not sent: \(wrapped.localizedDescription). It is back in the queue.", kind: .failure, seconds: 6)
      }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(6))
        self?.state.items.removeAll { $0.id == itemID && $0.isFailed }
      }
    }
  }

  private func update(_ id: UUID, _ change: (inout TranscriptItem) -> Void) {
    guard let index = state.items.firstIndex(where: { $0.id == id }) else { return }
    var item = state.items[index]
    change(&item)
    state.items[index] = item
  }

  /// Uploads what was picked. Images are staged on the Mac and go with the turn; files come back as
  /// `@file:` references.
  private func stage(
    _ picked: [ComposerAttachment], liveID: String, client: HermesClient
  ) async throws -> (references: [String], images: [StagedImage]) {
    var references: [String] = []
    var images: [StagedImage] = []
    for (offset, attachment) in picked.enumerated() {
      guard let data = attachment.data else { continue }
      uploadStatus = picked.count > 1 ? "Uploading \(offset + 1) of \(picked.count)" : "Uploading \(attachment.name)"
      switch attachment.kind {
      case .image:
        images.append(try await client.attachImage(liveID: liveID, profile: profile, data: data, filename: attachment.name))
      case .file:
        references.append(try await client.attachFile(
          liveID: liveID, profile: profile, data: data, name: attachment.name, mimeType: attachment.mimeType))
      }
    }
    uploadStatus = ""
    return (references, images)
  }

  /// Stop the reply. Whatever is queued waits until sent by hand or resumed: stopping means stop.
  func stop() async {
    queue.pause()
    await interrupt()
  }

  private func interrupt() async {
    guard let client else { return }
    do {
      try await ensureLive()
      guard let liveID else { return }
      try await client.interrupt(liveID: liveID, profile: profile)
      state.status = "Stopping"
    } catch {
      app?.show(error.localizedDescription, kind: .failure)
    }
  }

  // MARK: Queue

  /// Sends the next queued message once nothing runs.
  private func drainQueue() {
    guard !isClosed, !isLoading, !isReadOnly, !continuesAsNewVersion, let entry = queue.next(isBusy: isBusy) else { return }
    queue.remove(entry.id)
    Task { await deliver(text: entry.text, picked: entry.attachments, origin: .queue(entry)) }
  }

  /// "Send now": the running reply takes this message in and answers it. Words go straight into
  /// the reply (`session.redirect`). Photos need a turn of their own, so the reply stops and this
  /// message goes first. With nothing running it is simply sent.
  func sendNow(_ id: UUID) async {
    guard let entry = queue.entries.first(where: { $0.id == id }), !entry.isDelivering else { return }
    queue.resume()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if !isBusy {
      queue.remove(id)
      await deliver(text: entry.text, picked: entry.attachments, origin: .queue(entry))
      return
    }
    guard entry.attachments.isEmpty, !entry.text.isEmpty, state.isStreaming else {
      await goesNext(id)
      return
    }
    queue.setDelivering(id, true)
    do {
      try await ensureLive()
      guard let liveID, let client else { throw HermesError.notConnected }
      let status = try await client.redirect(liveID: liveID, profile: profile, text: entry.text)
      switch status {
      case "redirected":
        queue.remove(id)
        var next = state
        next.insertCorrection(entry.text, now: now)
        state = next
        hasSpoken = true
        scrollToEnd += 1
      case "queued":
        // The reply was still starting: the Mac runs this as the very next turn.
        queue.remove(id)
        state.items.append(TranscriptItem(kind: .user, text: entry.text, timestamp: now))
        hasSpoken = true
        scrollToEnd += 1
        app?.show("Your Mac takes it right after this reply.")
      default:
        queue.setDelivering(id, false)
        await goesNext(id)
      }
    } catch {
      queue.setDelivering(id, false)
      let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
      if wrapped.isConnectionLoss || wrapped == .notConnected {
        app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure)
      } else {
        // This reply cannot take messages in (an older agent): stop it and send this first.
        await goesNext(id)
      }
    }
  }

  /// Makes an entry the next to go and ends the reply, so it goes out as soon as the reply stops.
  private func goesNext(_ id: UUID) async {
    queue.promote(id)
    queue.resume()
    // A reply that already ended without telling us would never hand over to the queue. Finding
    // that out re-attaches, and the idle chat drains the queue on its own.
    await confirmStillRunning()
    guard queue.entries.contains(where: { $0.id == id }) else { return }
    if state.isStreaming { await interrupt() } else { drainQueue() }
  }

  /// Takes a queued message back into the composer to change it.
  func editQueued(_ id: UUID) {
    guard let entry = queue.remove(id) else { return }
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = [entry.text, current].filter { !$0.isEmpty }.joined(separator: "\n\n")
    attachments = entry.attachments + attachments
  }

  func deleteQueued(_ id: UUID) {
    queue.remove(id)
  }

  func resumeQueue() {
    queue.resume()
    drainQueue()
  }

  /// The app is going to sleep, or this chat is closing, while messages wait for a reply that is
  /// still running. Hand them to the Mac, which runs them after the reply with this app suspended
  /// (`prompt.submit` with `queued`). A paused queue stays here: the person stopped the agent.
  func handOffQueue() async {
    guard !queue.isEmpty, !queue.isPaused, isBusy, !continuesAsNewVersion, let client, let liveID else { return }
    for entry in queue.entries {
      do {
        let staged = try await stage(entry.attachments, liveID: liveID, client: client)
        let full = ([entry.text] + staged.references).filter { !$0.isEmpty }.joined(separator: "\n\n")
        _ = try await client.submit(liveID: liveID, profile: profile, text: full, queued: true, images: staged.images)
        // Shown as waiting on the Mac until the Mac starts its turn; not in the transcript yet.
        queue.moveToMac(entry.id)
        hasSpoken = true
      } catch {
        return
      }
    }
  }

  // MARK: Attachments

  func addImage(data: Data, name: String) {
    var attachment = ComposerAttachment(kind: .image, name: name)
    let id = attachment.id
    attachment.mimeType = "image/jpeg"
    attachments.append(attachment)
    Task {
      let prepared = await ImagePreparation.prepare(data, name: name)
      guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
      if let prepared {
        attachments[index].data = prepared.data
        attachments[index].name = prepared.name
        attachments[index].thumbnail = prepared.thumbnail
        attachments[index].status = .ready
      } else {
        attachments[index].status = .failed("Could not read the image")
      }
    }
  }

  func addFile(data: Data, name: String, mimeType: String) {
    var attachment = ComposerAttachment(kind: .file, name: name)
    attachment.mimeType = mimeType
    if data.count > 200_000_000 {
      attachment.status = .failed("Larger than 200 MB")
    } else {
      attachment.data = data
      attachment.status = .ready
    }
    attachments.append(attachment)
  }

  func removeAttachment(_ id: UUID) {
    attachments.removeAll { $0.id == id }
  }

  // MARK: Model and effort

  /// Loads the providers and their models. What is on screen stays while a fresh copy loads, and
  /// a plan the backend had not checked yet is looked at again shortly.
  func loadCatalog() async {
    guard let client else { return }
    catalogError = nil
    for attempt in 0..<2 {
      do {
        try await ensureLive()
        guard let liveID else { return }
        let fresh = try await client.modelCatalog(liveID: liveID, profile: profile)
        if fresh != catalog { catalog = fresh }
        guard attempt == 0, fresh.contains(where: \.isCheckingPlan) else { return }
        try await Task.sleep(for: .seconds(4))
      } catch is CancellationError {
        return
      } catch {
        if catalog == nil { catalogError = error.localizedDescription }
        return
      }
    }
  }

  /// Switches this conversation's model. Returns a confirmation prompt when the backend wants one.
  func setModel(_ model: String, provider: String, confirmed: Bool = false) async -> String? {
    guard let client else { return nil }
    do {
      try await ensureLive()
      guard let liveID else { return nil }
      let result = try await client.setModel(liveID: liveID, profile: profile, model: model, provider: provider, confirmed: confirmed)
      if result.needsConfirmation {
        return result.confirmationMessage.isEmpty
          ? "\(ModelName(model).display) costs more than usual. Use it for this chat?" : result.confirmationMessage
      }
      state.info.model = result.model
      state.info.provider = provider
      preferredModel = result.model
      preferredProvider = provider
      catalog = nil
      let name = ModelName(result.model).display
      app?.show(result.isDeferred ? "\(name) takes over after this reply" : "This chat now uses \(name)", kind: .success)
      if !result.warning.isEmpty { app?.show(result.warning, seconds: 5) }
    } catch {
      app?.show("Could not switch model: \(error.localizedDescription)", kind: .failure)
    }
    return nil
  }

  func setEffort(_ effort: String) async {
    guard let client else { return }
    do {
      try await ensureLive()
      guard let liveID else { return }
      let settled = try await client.setReasoningEffort(liveID: liveID, profile: profile, effort: effort)
      state.info.reasoningEffort = settled
      preferredEffort = settled
    } catch {
      app?.show("Could not change effort: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Metadata

  func rename(to title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let client else { return }
    do {
      if let liveID, !continuesAsNewVersion {
        try await client.setTitle(liveID: liveID, profile: profile, title: trimmed)
      } else if let row = app?.row(storedID) {
        try await client.update(row, title: trimmed)
      }
      state.title = trimmed
      app?.scheduleReload(after: 0.4)
    } catch {
      app?.show("Could not rename: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Leaving

  func leave() {
    isClosed = true
    watchTask?.cancel()
    watchTask = nil
    livenessTask?.cancel()
    livenessTask = nil
    app?.preferences.setDraft(draft, for: storedID)
    if !queue.isEmpty {
      Task {
        await handOffQueue()
        keepQueueAsDraft()
      }
    }
    // Stop following the chat once nothing here waits on it. A running reply stays followed, so a
    // question it asks still reaches this app.
    if let liveID, let client, !state.isStreaming, !isSending, queue.isEmpty {
      let subscription = subscriptionID
      let profile = profile
      subscriptionID = ""
      Task { try? await client.detach(liveID: liveID, subscriptionID: subscription, profile: profile) }
    }
  }

  /// Queued messages that could not go to the Mac (the queue was paused, or the handover failed)
  /// become the chat's draft, so nothing typed is lost when the chat closes.
  private func keepQueueAsDraft() {
    let left = queue.removeAll().map(\.text).filter { !$0.isEmpty }
    guard !left.isEmpty else { return }
    draft = ([draft.trimmingCharacters(in: .whitespacesAndNewlines)] + left).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// The phone is going to sleep. Messages waiting for the running reply go to the Mac now, or
  /// they would wait until the app is opened again.
  func wentToBackground() {
    guard !queue.isEmpty, !queue.isPaused, isBusy else { return }
    let task = BackgroundTask()
    task.id = UIApplication.shared.beginBackgroundTask(withName: "Hand queued messages to the Mac") { task.end() }
    Task {
      await handOffQueue()
      task.end()
    }
  }
}

/// Extra time iOS grants an app that is going to the background, ended once the work is done.
@MainActor private final class BackgroundTask {
  var id = UIBackgroundTaskIdentifier.invalid

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}

/// Shrinks a picked photo to what a model can use (2048 px on the long side) and makes a thumbnail.
enum ImagePreparation {
  struct Prepared: Sendable {
    let data: Data
    let name: String
    let thumbnail: UIImage
  }

  nonisolated static func prepare(_ data: Data, name: String) async -> Prepared? {
    await Task.detached(priority: .userInitiated) {
      guard let image = UIImage(data: data) else { return nil }
      let full = resized(image, maxSide: 2048)
      guard let jpeg = full.jpegData(compressionQuality: 0.86) else { return nil }
      let base = (name as NSString).deletingPathExtension
      // The thumbnail is what the message shows until the Mac's copy loads, so it is screen sized.
      return Prepared(data: jpeg, name: (base.isEmpty ? "image" : base) + ".jpg", thumbnail: resized(image, maxSide: 720))
    }.value
  }

  nonisolated private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    let scale = min(1, maxSide / max(longest, 1))
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
