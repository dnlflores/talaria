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
/// The behavior follows the hermesdash web client. Two rules shape most of it:
/// - The backend allows one live owner per conversation. A chat that the desktop app or a
///   terminal has open is shown read-only and kept fresh by polling; sending continues it
///   as a new version (a branch) that this app owns.
/// - A dropped socket loses the live session. On return the chat re-attaches and folds the
///   fresh transcript into what is on screen without rebuilding it.
@MainActor @Observable
final class ChatModel: Identifiable {
  let profile: String
  private(set) var storedID: String
  private(set) var liveID: String?
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
  /// Bumped when the view should scroll to the newest message.
  private(set) var scrollToEnd = 0

  var draft: String { didSet { app?.preferences.setDraft(draft, for: storedID) } }
  var attachments: [ComposerAttachment] = []
  var sendWhenReady = false

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
  var canSend: Bool {
    guard !isReadOnly, !isSending, !isBranching else { return false }
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
      adopt(live, replacingTranscript: true)
      isLoading = false
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
      return
    }

    // Ask who has it open right before deciding how to open it.
    async let freshRow = try? client.session(storedID: storedID, profile: profile)
    async let freshActive = try? client.activeSessions()
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
    do {
      try await client.rpc.waitUntilReady(timeout: 45)
      let live = try await client.resume(storedID: storedID, profile: profile)
      if isClosed { return }
      adopt(live, replacingTranscript: true)
      isLoading = false
      await fillClarifyAnswers()
      if let row = app?.row(storedID), row.unread { app?.setUnread(row, false) }
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
    } catch {
      if isClosed { return }
      loadError = error.localizedDescription
      if let stored = try? await client.storedMessages(storedID: storedID, profile: profile) {
        state.items = TranscriptItem.items(fromStoredRows: stored)
        isReadOnly = true
      }
      isLoading = false
    }
  }

  private func adopt(_ live: LiveSession, replacingTranscript: Bool) {
    liveID = live.liveID
    app?.noteLive(live.liveID, storedID: storedID)
    var next = state
    next.info.merge(live.info)
    if next.title.isEmpty { next.title = next.info.title }
    let fresh = TranscriptItem.items(fromHistory: live.messages)
    if replacingTranscript {
      next.items = fresh
      next.applyInflight(live.inflight, turnStartedAt: live.turnStartedAt, now: now)
    } else {
      next.reconcile(fresh: fresh, inflight: live.inflight, turnStartedAt: live.turnStartedAt, now: now)
    }
    next.applyLiveStatus(isRunning: live.isRunning, startedAt: live.turnStartedAt, now: now)
    state = next
    lastEventAt = Date()
    for request in live.openRequests { app?.deliver(request) }
    if live.isRunning { Task { await fillRunningTools() } }
  }

  /// `session.resume` lists a tool call only once its result is stored, so a chat opened while
  /// a tool runs would say "Thinking". The stored rows name the call as soon as it starts.
  private func fillRunningTools() async {
    guard state.isStreaming, let client,
      let rows = try? await client.latestMessages(storedID: storedID, profile: profile, limit: 12), !isClosed
    else { return }
    var next = state
    if next.addRunningTools(fromStoredRows: rows, now: now) { state = next }
  }

  /// Past questions: the resumed transcript names them but leaves out the answers, which live in the stored rows.
  private func fillClarifyAnswers() async {
    let missing = state.items.contains { $0.tool?.isClarify == true && $0.tool?.answers == nil && $0.tool?.pendingRequest == nil && $0.tool?.isDone == true }
    guard missing, let client, let stored = try? await client.storedMessages(storedID: storedID, profile: profile) else { return }
    var results: [String: String] = [:]
    for row in stored where row["role"].string == "tool" {
      if let id = row["tool_call_id"].scalarText, let content = row["content"].string { results[id] = content }
    }
    var next = state
    for index in next.items.indices {
      guard var tool = next.items[index].tool, tool.isClarify, tool.answers == nil, let raw = results[tool.callID] else { continue }
      tool.answers = ClarifyAnswer.parse(raw, questionCount: tool.questions.count)
      next.items[index].tool = tool
    }
    state = next
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
    let fresh = TranscriptItem.items(fromStoredRows: try await client.storedMessages(storedID: storedID, profile: profile))
    if isClosed { return }
    if first || state.items.isEmpty {
      state.items = fresh
    } else {
      var next = state
      next.reconcile(fresh: fresh, inflight: nil, now: now)
      if next != state { state = next }
    }
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
      await fillClarifyAnswers()
    } catch {
      if !isClosed { app?.show("Could not reopen the chat: \(error.localizedDescription)", kind: .failure) }
    }
  }

  private func dropLive() async {
    var ids = Set<String>()
    if let liveID { ids.insert(liveID) }
    liveID = nil
    guard let client else { return }
    if let active = try? await client.activeSessions() {
      for entry in active where entry["session_key"].string == storedID {
        if let id = entry["id"].string { ids.insert(id) }
      }
    }
    for id in ids { try? await client.close(liveID: id) }
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
        live = try await client.resume(storedID: self.storedID, profile: self.profile, lazy: !spoken)
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
      self.adopt(live, replacingTranscript: false)
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
    guard state.isStreaming else { return }
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
    guard let active = try? await client.activeSessions() else { return }
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
    Task { await client?.answer(outcome.request, result: outcome.result) }
  }

  // MARK: Sending

  func send() async {
    guard !isReadOnly, !isSending else { return }
    if continuesAsNewVersion {
      if canSend { await continueAsNewVersion(send: true) }
      return
    }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let picked = attachments.filter(\.isUsable)
    guard !text.isEmpty || !picked.isEmpty, let client else { return }

    draft = ""
    attachments = []
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
    }

    do {
      var status = ""
      var attempt = 0
      while true {
        do {
          try await ensureLive()
          guard let liveID else { throw HermesError.notConnected }
          let references = try await stage(picked, liveID: liveID, client: client)
          let full = ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n\n")
          update(itemID) { $0.sentText = full }
          state.beginTurn(now: now)
          status = try await client.submit(liveID: liveID, profile: profile, text: full)
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
      if status == "queued" { app?.show("Queued. It goes out after the current reply.") }
      if state.title.isEmpty { state.title = String((text.isEmpty ? picked.first?.name ?? "" : text).prefix(60)) }
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
      if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
      attachments = picked + attachments
      app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure, seconds: 6)
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

  /// Uploads what was picked. Images are queued on the session; files come back as `@file:` references.
  private func stage(_ picked: [ComposerAttachment], liveID: String, client: HermesClient) async throws -> [String] {
    var references: [String] = []
    for (offset, attachment) in picked.enumerated() {
      guard let data = attachment.data else { continue }
      uploadStatus = picked.count > 1 ? "Uploading \(offset + 1) of \(picked.count)" : "Uploading \(attachment.name)"
      switch attachment.kind {
      case .image:
        try await client.attachImage(liveID: liveID, profile: profile, data: data, filename: attachment.name)
      case .file:
        references.append(try await client.attachFile(
          liveID: liveID, profile: profile, data: data, name: attachment.name, mimeType: attachment.mimeType))
      }
    }
    uploadStatus = ""
    return references
  }

  func stop() async {
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

  func loadCatalog() async {
    guard catalog == nil, let client else { return }
    catalogError = nil
    do {
      try await ensureLive()
      guard let liveID else { return }
      catalog = try await client.modelCatalog(liveID: liveID, profile: profile)
    } catch {
      catalogError = error.localizedDescription
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
        return result.confirmationMessage.isEmpty ? "\(model) costs more than usual. Use it for this chat?" : result.confirmationMessage
      }
      state.info.model = result.model
      state.info.provider = provider
      preferredModel = result.model
      preferredProvider = provider
      catalog = nil
      app?.show(result.isDeferred ? "\(model) takes over after this reply" : "This chat now uses \(model)", kind: .success)
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
    if let liveID, hasSpoken { app?.scheduleRelease(liveID: liveID, storedID: storedID) }
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
      return Prepared(data: jpeg, name: (base.isEmpty ? "image" : base) + ".jpg", thumbnail: resized(image, maxSide: 160))
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
