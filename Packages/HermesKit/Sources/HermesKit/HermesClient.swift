import Foundation

/// What `session.resume`, `session.create` and a branch hand back: the gateway's snapshot of a chat.
public struct LiveSession: Sendable {
  /// The id events are addressed to. The gateway uses the stored id itself.
  public let liveID: String
  /// Id of the stored conversation the sidebar lists.
  public let storedID: String
  public let messages: [JSONValue]
  /// The running turn's text so far, which a snapshot leaves out (see `HermesClient.inflight`).
  public let inflight: JSONValue
  public let openRequests: [ServerRequest]
  public let info: JSONValue
  /// A turn is running in this session right now (thinking, running a tool, or streaming).
  public let isRunning: Bool
  /// When that turn started, seconds since 1970.
  public let turnStartedAt: Double?
  /// This socket's attachment to the chat; `HermesClient.detach` ends it.
  public let subscriptionID: String
  /// Messages waiting in the Mac's queue for this chat, from any device; nil from a gateway
  /// that does not list them.
  public let pending: [QueuedOnMac]?

  init(json: JSONValue, fallbackStoredID: String = "", inflight: JSONValue? = nil) {
    liveID = json["session_id"].string ?? fallbackStoredID
    storedID = json["stored_session_id"].string ?? (fallbackStoredID.isEmpty ? json["session_id"].stringValue : fallbackStoredID)
    messages = json["display_messages"].array ?? json["messages"].array ?? []
    self.inflight = inflight ?? json["inflight"]
    info = json["info"]
    let status = json["status"].stringValue
    isRunning = json["running"].truthy || ["working", "streaming", "waiting"].contains(status)
    turnStartedAt = json["turn_started_at"].double
    subscriptionID = json["subscription_id"].stringValue
    pending = QueuedOnMac.list(json["pending"])
    let liveID = self.liveID
    // Questions still waiting: the gateway's own requests (sudo, secret) and the chat's prompts.
    let requests = (json["open_requests"].array ?? []).compactMap { item -> ServerRequest? in
      guard let method = item["method"].string, !item["id"].isNull else { return nil }
      return ServerRequest(rawID: item["id"], method: method, params: item["params"])
    }
    let prompts = (json["prompts"].array ?? []).compactMap { prompt in
      ServerRequest.prompt(kind: prompt["kind"].stringValue, sessionID: liveID, payload: prompt)
    }
    openRequests = requests + prompts
  }
}

public struct NewSessionOptions: Sendable {
  public var title: String?
  public var model: String?
  public var provider: String?
  public var reasoningEffort: String?
  public var cwd: String?

  public init(title: String? = nil, model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, cwd: String? = nil) {
    self.title = title
    self.model = model
    self.provider = provider
    self.reasoningEffort = reasoningEffort
    self.cwd = cwd
  }
}

public struct ModelSwitchResult: Sendable {
  public let model: String
  /// The backend wants a second, confirmed call before using a costly model.
  public let needsConfirmation: Bool
  public let confirmationMessage: String
  /// Takes effect after the running reply.
  public let isDeferred: Bool
  public let warning: String
}

/// The Hermes gateway as this app uses it: REST through the gate plus JSON-RPC over the WebSocket.
///
/// Method names and shapes follow the gateway contract shipped with Hermes
/// (`apps/shared/src/gateway-contract.openrpc.json`), checked against 0.23.1.
public final class HermesClient: Sendable {
  public let endpoint: ServerEndpoint
  public let http: HermesHTTP
  public let rpc: RPCConnection

  public init(endpoint: ServerEndpoint, signIns: any SignInStore) {
    self.endpoint = endpoint
    http = HermesHTTP(endpoint: endpoint, signIns: signIns)
    rpc = RPCConnection(endpoint: endpoint, http: http)
  }

  // MARK: Lists

  public func sessions(recents: Int = 200, messaging: Int = 200, cron: Int = 50) async throws -> [SessionSummary] {
    let json = try await http.json("GET", "/api/profiles/sessions/sidebar", query: [
      ("recents_limit", String(recents)), ("messaging_limit", String(messaging)), ("cron_limit", String(cron)),
    ])
    return SessionGrouping.rows(fromSidebar: json)
  }

  /// The few newest chats of every bot: a light look (about 20 KB) at which turns are running,
  /// including ones another Hermes process runs, which send this app no events.
  public func recentActivity() async throws -> [SessionSummary] {
    let json = try await http.json("GET", "/api/profiles/sessions/sidebar", query: [
      ("recents_limit", "5"), ("messaging_limit", "3"), ("cron_limit", "0"),
    ], timeout: 15)
    return SessionGrouping.rows(fromSidebar: json)
  }

  /// One bot's newest conversations. The inbox load caps rows across all bots, so a quiet bot
  /// can be missing from it entirely.
  public func sessions(profile: String, limit: Int) async throws -> [SessionSummary] {
    let json = try await http.json("GET", "/api/profiles/sessions/sidebar", query: [
      ("recents_profile", profile), ("recents_limit", String(limit)), ("messaging_limit", "1"), ("cron_limit", "1"),
    ], timeout: 20)
    return SessionGrouping.rows(fromSidebar: json)
  }

  /// How many conversations a bot has on the Mac, counted as the inbox lists them (with at
  /// least one message, not archived).
  public func sessionCount(profile: String) async throws -> Int {
    let json = try await http.json("GET", "/api/sessions", query: [
      ("profile", profile), ("limit", "0"), ("min_messages", "1"),
    ], timeout: 15)
    return json["total"].int ?? 0
  }

  /// A page of one bot's conversations, newest activity first.
  public func sessionPage(profile: String, offset: Int, limit: Int = 50) async throws -> (rows: [SessionSummary], total: Int) {
    let json = try await http.json("GET", "/api/sessions", query: [
      ("profile", profile), ("limit", String(limit)), ("offset", String(offset)),
      ("order", "recent"), ("min_messages", "1"),
    ], timeout: 30)
    let rows = (json["sessions"].array ?? []).map { row -> SessionSummary in
      var session = SessionSummary(json: row)
      if row["profile"].string == nil { session.profile = profile }
      return session
    }
    return (rows, json["total"].int ?? rows.count)
  }

  /// One page of a conversation's stored rows: `limit` rows, `offset` rows back from the newest,
  /// oldest first. Rows archived by compaction are included, so the whole conversation can be
  /// paged through (the desktop app reads its transcripts this way).
  public func historyPage(storedID: String, profile: String, offset: Int, limit: Int) async throws -> [JSONValue] {
    let json = try await http.json("GET", "/api/sessions/\(storedID)/messages", query: [
      ("profile", profile), ("limit", String(limit)), ("offset", String(offset)), ("order", "latest"),
      ("include_compacted", "true"), ("inline_images", "false"),
    ], timeout: 45)
    return json["messages"].array ?? []
  }

  /// The newest few stored rows of a conversation, oldest first, without inline images.
  public func latestMessages(storedID: String, profile: String, limit: Int = 8) async throws -> [JSONValue] {
    let json = try await http.json("GET", "/api/sessions/\(storedID)/messages", query: [
      ("profile", profile), ("limit", String(limit)), ("order", "latest"), ("inline_images", "false"),
    ], timeout: 20)
    return json["messages"].array ?? []
  }

  public func profiles() async throws -> [Profile] {
    let json: JSONValue
    do {
      json = try await rpc.call("profiles.list", ["include_sessions": false], timeout: 30)
    } catch {
      json = try await http.json("GET", "/api/profiles")
    }
    var rows = json["profiles"].array ?? []
    // The gateway's list leaves a bot's model and provider empty unless it is the default; the
    // REST list names them for every bot (and lacks the bot's look, which the gateway's has).
    if rows.contains(where: { $0["model"].stringValue.isEmpty }),
      let rest = try? await http.json("GET", "/api/profiles", timeout: 15)
    {
      let byName = Dictionary((rest["profiles"].array ?? []).map { ($0["name"].stringValue, $0) }, uniquingKeysWith: { a, _ in a })
      rows = rows.map { row in
        guard case .object(var fields) = row, let other = byName[row["name"].stringValue] else { return row }
        for key in ["model", "provider"] where row[key].stringValue.isEmpty && !other[key].stringValue.isEmpty {
          fields[key] = other[key]
        }
        return .object(fields)
      }
    }
    return rows.map(Profile.init(json:)).filter { !$0.name.isEmpty }
  }

  /// PNG/JPEG bytes of a profile's avatar, when it has one.
  public func avatar(profile: String) async throws -> Data? {
    let json = try await rpc.call("profiles.get_asset", ["name": .string(profile), "asset": "avatar"], timeout: 30)
    guard json["found"].truthy, let dataURL = json["data"].string, let comma = dataURL.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
  }

  /// Chats another Hermes process on the Mac holds right now, keyed by stored session id. Hermes'
  /// own listener has no such list: chats the gateway runs (the desktop app's included) are shared
  /// live, and a turn a separate process runs shows through the row heartbeat
  /// (`SessionSummary.isTurnRunning`) instead.
  public func owners() async throws -> [String: ChatOwner] {
    [:]
  }

  public func status() async throws -> JSONValue {
    try await http.json("GET", "/api/status", timeout: 15)
  }

  /// The Mac's home folder, for showing a chat folder there as `~`. Hermes does not report it, but
  /// the default profile lives in `<home>/.hermes`; empty when it lives somewhere else.
  public func macHome() async throws -> String {
    let json = try await http.json("GET", "/api/profiles", timeout: 15)
    let rows = json["profiles"].array ?? json.array ?? []
    guard let row = rows.first(where: { $0["is_default"].truthy }) ?? rows.first(where: { $0["name"] == "default" }) else {
      return ""
    }
    return Self.home(fromDefaultProfilePath: row["path"].stringValue)
  }

  static func home(fromDefaultProfilePath path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    guard trimmed.hasSuffix("/.hermes") else { return "" }
    return String(trimmed.dropLast("/.hermes".count))
  }

  // MARK: Opening conversations

  /// Attaches this socket to a chat on the gateway (the process the desktop app runs its chats
  /// in) and returns its snapshot. The desktop and this app are then two views of the same live
  /// chat: each sees the other's turns, thinking and questions as they happen.
  /// `omitMessages` leaves the transcript out (a long chat's runs to megabytes): read it a page
  /// at a time with `historyPage` instead, as the desktop app does. `lazy` is accepted for older
  /// callers and means nothing on the gateway.
  public func resume(storedID: String, profile: String, lazy: Bool = false, omitMessages: Bool = false) async throws -> LiveSession {
    let params = JSONValue.fields([
      "session_id": .string(storedID), "profile": .string(profile), "cols": 100,
      // The transcript as the desktop shows it (`display_messages`), not raw model rows.
      "omit_messages": omitMessages ? true : nil, "display_projection": omitMessages ? nil : true,
    ])
    let json = try await rpc.call("session.resume", params, timeout: 90)
    let liveID = json["session_id"].string ?? storedID
    return LiveSession(json: json, fallbackStoredID: storedID, inflight: await inflight(liveID: liveID, profile: profile, snapshot: json))
  }

  public func create(profile: String, options: NewSessionOptions = NewSessionOptions()) async throws -> LiveSession {
    let hasModel = !(options.model ?? "").isEmpty
    let hasCwd = !(options.cwd ?? "").isEmpty
    // `gui`: the chat gets the desktop app's policy and shows there as one of its own chats.
    let params = JSONValue.fields([
      "profile": .string(profile), "source": "gui", "request_id": .string(UUID().uuidString.lowercased()),
      "title": options.title.flatMap { $0.isEmpty ? nil : .string($0) },
      "model": hasModel ? options.model.map(JSONValue.string) : nil,
      "provider": hasModel ? options.provider.flatMap { $0.isEmpty ? nil : .string($0) } : nil,
      "reasoning": options.reasoningEffort.flatMap { $0.isEmpty ? nil : .string($0) },
      "cwd": hasCwd ? options.cwd.map(JSONValue.string) : nil,
      "cwd_explicit": hasCwd ? true : nil,
    ])
    return LiveSession(json: try await rpc.call("session.create", params, timeout: 90))
  }

  /// Copies a whole stored conversation into a new one. Used to continue a messaging thread
  /// (which belongs to its platform) as a Hermes chat. The copy keeps the parent's model.
  public func branch(storedID: String, profile: String, cwd: String, model: String, provider: String) async throws -> LiveSession {
    // The branch is a change to the parent, fenced like any other: attach to it first.
    _ = try await resume(storedID: storedID, profile: profile, omitMessages: true)
    let result = try await mutate(storedID, profile: profile, operation: "branch", payload: [:])
    guard let child = result["branched_session_id"].string, !child.isEmpty else {
      throw HermesError.invalidResponse("the branch named no new chat")
    }
    return try await resume(storedID: child, profile: profile, omitMessages: false)
  }

  /// A running turn's text so far. A snapshot leaves it out; the gateway's replay buffer still
  /// holds the turn's events, which are folded into the `inflight` shape the chat state takes.
  private func inflight(liveID: String, profile: String, snapshot: JSONValue) async -> JSONValue? {
    guard snapshot["running"].truthy, let epoch = snapshot["replay_epoch"].string else { return nil }
    let params: JSONValue = [
      "session_id": .string(liveID), "profile": .string(profile), "last_sequence": 0, "replay_epoch": .string(epoch),
    ]
    guard let replay = try? await rpc.call("session.events.since", params, timeout: 30) else { return nil }
    return Self.inflight(fromReplay: replay["events"].array ?? [], generation: snapshot["execution_generation"].int)
  }

  /// The running turn's `inflight`, rebuilt from its replayed events in the shape `hermes serve`
  /// sent: `assistant` is every `message.delta` of the turn joined as streamed (notes the history
  /// already holds included; `ChatState.applyInflight` adds only the rest). Notes sent only as
  /// `message.interim` are not in it, as they were not in serve's. Only the running turn's events
  /// count (`generation`).
  static func inflight(fromReplay events: [JSONValue], generation: Int?) -> JSONValue? {
    var streamed = ""
    var started = false
    var admissionID: String?
    for event in events {
      if let generation, let own = event["execution_generation"].int, own != generation { continue }
      switch event["type"].stringValue {
      case "message.start":
        started = true
        admissionID = event["admission_id"].string
      case "message.delta": streamed += event["payload"]["text"].stringValue
      default: break
      }
    }
    guard started else { return nil }
    return .fields(["assistant": .string(streamed), "streaming": true, "admission_id": admissionID.map(JSONValue.string)])
  }

  /// One stored conversation's row, with its heartbeat.
  public func session(storedID: String, profile: String) async throws -> SessionSummary {
    var json = try await http.json("GET", "/api/sessions/\(storedID)", query: [("profile", profile)], timeout: 15)
    if json["profile"].string == nil, case .object(var fields) = json {
      fields["profile"] = .string(profile)
      json = .object(fields)
    }
    return SessionSummary(json: json)
  }

  /// The stored transcript, for conversations this client cannot attach to.
  public func storedMessages(storedID: String, profile: String) async throws -> [JSONValue] {
    let json = try await http.json("GET", "/api/sessions/\(storedID)/messages", query: [("profile", profile)], timeout: 45)
    return json["messages"].array ?? []
  }

  /// The chats the gateway has live, with what each is doing (`working`, `waiting`, `idle`).
  /// Each bot is its own profile on the gateway, so every one named is asked.
  public func activeSessions(profiles: [String] = ["default"]) async throws -> [JSONValue] {
    let names = Array(Set(profiles.isEmpty ? ["default"] : profiles))
    return try await withThrowingTaskGroup(of: [JSONValue].self) { group in
      for name in names {
        group.addTask {
          let rows = try await self.rpc.call("session.active_list", ["profile": .string(name)], timeout: 15)["sessions"].array ?? []
          return rows.map { row in
            guard case .object(var fields) = row else { return row }
            fields["profile"] = .string(name)
            return .object(fields)
          }
        }
      }
      var out: [JSONValue] = []
      for try await rows in group { out += rows }
      return out
    }
  }

  /// Stops this socket following a chat it left, as the desktop app does. Nothing is locked by
  /// following one (the desktop reaches it whatever this app does); this only stops its events.
  public func detach(liveID: String, subscriptionID: String, profile: String) async throws {
    guard !subscriptionID.isEmpty else { return }
    _ = try await rpc.call(
      "session.detach",
      ["session_id": .string(liveID), "profile": .string(profile), "subscription_id": .string(subscriptionID)], timeout: 15)
  }

  // MARK: Turns

  /// Sends a user turn. The gateway admits it into the chat's queue and runs it next; while a
  /// reply runs it waits behind it. `queued` marks a message that waited for the reply before it.
  /// `images` are pictures staged with `attachImage`. Returns `streaming` once admitted.
  @discardableResult
  public func submit(
    liveID: String, profile: String, text: String, queued: Bool = false, images: [StagedImage] = []
  ) async throws -> String {
    _ = try await admit(liveID: liveID, profile: profile, text: text, queued: queued, images: images)
    return "streaming"
  }

  /// Keep a queued prompt's durable receipt and reuse its identity after an uncertain handoff.
  public func admit(
    liveID: String, profile: String, text: String, queued: Bool = false, images: [StagedImage] = [],
    submissionID: String = UUID().uuidString.lowercased()
  ) async throws -> JSONValue {
    var params: [String: JSONValue] = [
      "session_id": .string(liveID), "profile": .string(profile), "text": .string(text),
      "submission_id": .string(submissionID),
    ]
    if queued { params["queued"] = true }
    if !images.isEmpty {
      params["attachments"] = .array(images.map { ["path": .string($0.path), "mime": .string($0.mime)] })
    }
    let receipt = try await rpc.call("prompt.submit", .object(params), timeout: 60)
    guard receipt["admission_id"].string != nil else { throw HermesError.invalidResponse("the Mac did not take the message") }
    return receipt
  }

  public func receipt(liveID: String, profile: String, admissionID: String) async throws -> JSONValue {
    try await rpc.call("prompt.receipt", [
      "session_id": .string(liveID), "profile": .string(profile), "admission_id": .string(admissionID),
    ], timeout: 15)
  }

  /// Cancels this exact waiting admission, not the unrelated turn currently running.
  public func cancelAdmission(liveID: String, profile: String, admissionID: String) async throws {
    _ = try await rpc.call("prompt.cancel", [
      "session_id": .string(liveID), "profile": .string(profile), "admission_id": .string(admissionID),
    ], timeout: 15)
  }

  /// Hands a message waiting in the Mac's queue to the running reply, which takes it in after
  /// the step it is on (`prompt.steer_queued`). Works on any device's text-only message. Refused
  /// (`steer_unavailable`, `session_idle`, `admission_started`, `unsupported_control`) leaves it
  /// queued.
  public func steerQueued(liveID: String, profile: String, admissionID: String) async throws -> JSONValue {
    try await rpc.call("prompt.steer_queued", [
      "session_id": .string(liveID), "profile": .string(profile), "admission_id": .string(admissionID),
    ], timeout: 15)
  }

  /// Hands a message to the running reply: the agent takes it in now and answers it (the model
  /// call in flight restarts with it, or it waits for the step that is running). Answers
  /// `redirected`, `queued` (the reply was still starting; it goes out next), or `rejected`.
  public func redirect(liveID: String, profile: String, text: String) async throws -> String {
    let result = try await fenced(liveID, profile: profile) { generation in
      try await self.rpc.call(
        "session.redirect",
        ["session_id": .string(liveID), "profile": .string(profile), "execution_generation": .number(Double(generation)),
         "text": .string(text)], timeout: 30)
    }
    return result["status"].stringValue
  }

  public func interrupt(liveID: String, profile: String) async throws {
    _ = try await fenced(liveID, profile: profile) { generation in
      try await self.rpc.call(
        "session.interrupt",
        ["session_id": .string(liveID), "profile": .string(profile), "execution_generation": .number(Double(generation))],
        timeout: 30)
    }
  }

  /// Runs a turn control with the chat's current generation, and once more with a fresh one when
  /// the turn moved on meanwhile.
  private func fenced(_ liveID: String, profile: String, _ call: (Int) async throws -> JSONValue) async throws -> JSONValue {
    var generation = await rpc.fences(for: liveID).generation
    if generation == nil {
      _ = try await resume(storedID: liveID, profile: profile, omitMessages: true)
      generation = await rpc.fences(for: liveID).generation
    }
    do {
      return try await call(generation ?? 0)
    } catch let error as HermesError where error.isStaleFence {
      return try await call(await rpc.fences(for: liveID).generation ?? 0)
    }
  }

  /// A change to a chat's settings or metadata (`model`, `reasoning`, `rename`, `archive`,
  /// `branch`), fenced by its revision and generation; retried once at fresh fences.
  @discardableResult
  public func mutate(
    _ sessionID: String, profile: String, operation: String, payload: JSONValue, withGeneration: Bool = true
  ) async throws -> JSONValue {
    var fences = await rpc.fences(for: sessionID)
    if fences.revision == nil || (withGeneration && fences.generation == nil) {
      _ = try await resume(storedID: sessionID, profile: profile, omitMessages: true)
      fences = await rpc.fences(for: sessionID)
    }
    func send(_ fences: SessionFences) async throws -> JSONValue {
      try await rpc.call("session.mutate", JSONValue.fields([
        "session_id": .string(sessionID), "profile": .string(profile), "request_id": .string(UUID().uuidString.lowercased()),
        "expected_revision": .number(Double(fences.revision ?? 0)),
        "expected_generation": withGeneration ? .number(Double(fences.generation ?? 0)) : nil,
        "operation": .string(operation), "payload": payload,
      ]), timeout: 60)
    }
    do {
      return try await send(fences)
    } catch let error as HermesError where error.isStaleFence {
      return try await send(await rpc.fences(for: sessionID))
    }
  }

  /// Stages a picture for the next turn of this session; pass the result to `submit`.
  public func attachImage(liveID: String, profile: String, data: Data, filename: String) async throws -> StagedImage {
    let result = try await rpc.call(
      "image.attach_bytes",
      ["session_id": .string(liveID), "profile": .string(profile), "content_base64": .string(data.base64EncodedString()),
       "filename": .string(filename)], timeout: 240)
    guard result["attached"].truthy, let path = result["path"].string, !path.isEmpty else {
      throw HermesError.invalidResponse(result["message"].string ?? "\(filename) was not accepted")
    }
    return StagedImage(path: path, mime: result["mime"].string ?? "image/jpeg")
  }

  /// Stages a file in the session's workspace and returns the `@file:` reference to append to the prompt.
  public func attachFile(liveID: String, profile: String, data: Data, name: String, mimeType: String) async throws -> String {
    let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
    let result = try await rpc.call(
      "file.attach",
      ["session_id": .string(liveID), "profile": .string(profile), "name": .string(name), "data_url": .string(dataURL)],
      timeout: 300)
    guard result["attached"].truthy, let reference = result["ref_text"].string, !reference.isEmpty else {
      throw HermesError.invalidResponse(result["message"].string ?? "\(name) was not accepted")
    }
    return reference
  }

  // MARK: Model and effort (this conversation only)

  public func modelCatalog(liveID: String, profile: String) async throws -> [ModelProvider] {
    let json = try await rpc.call("model.options", ["session_id": .string(liveID), "profile": .string(profile)], timeout: 45)
    return ModelProvider.catalog(from: json)
  }

  /// Switches this chat's model. A costly model comes back needing confirmation: the gateway hands
  /// out a one-time token with the question, and the confirmed call (`confirmed`) presents it.
  public func setModel(liveID: String, profile: String, model: String, provider: String, confirmed: Bool = false) async throws -> ModelSwitchResult {
    let key = "\(profile)/\(liveID)/\(provider)/\(model)"
    var payload: [String: JSONValue] = ["model": .string(model), "provider": .string(provider)]
    if confirmed, let token = await rpc.takeConfirmation(key) { payload["confirm"] = .string(token) }
    let json = try await mutate(liveID, profile: profile, operation: "model", payload: .object(payload))
    let status = json["status"].stringValue
    if status == "confirmation_required", let token = json["confirm"].string {
      await rpc.rememberConfirmation(key, token: token)
    }
    return ModelSwitchResult(
      model: json["model"].string ?? model, needsConfirmation: status == "confirmation_required",
      confirmationMessage: json["confirm_message"].stringValue, isDeferred: status == "deferred",
      warning: json["warning"].stringValue)
  }

  /// Returns the effort the backend settled on.
  public func setReasoningEffort(liveID: String, profile: String, effort: String) async throws -> String {
    let json = try await mutate(liveID, profile: profile, operation: "reasoning", payload: ["effort": .string(effort)])
    return json["effort"].string ?? effort
  }

  // MARK: Conversation metadata

  public func setArchived(storedID: String, profile: String, archived: Bool) async throws {
    try await mutate(storedID, profile: profile, operation: "archive", payload: ["archived": .bool(archived)], withGeneration: false)
  }

  public func setTitle(liveID: String, profile: String, title: String) async throws {
    try await mutate(liveID, profile: profile, operation: "rename", payload: ["title": .string(title)], withGeneration: false)
  }

  /// Pin, unread, title and archive changes on a stored row. The backend fences these writes: each
  /// must carry a fresh request id and the revision it was based on, or it answers 409.
  public func update(
    _ session: SessionSummary, pinned: Bool? = nil, unread: Bool? = nil, title: String? = nil, archived: Bool? = nil
  ) async throws {
    func body(revision: Int) -> JSONValue {
      JSONValue.fields([
        "request_id": .string(UUID().uuidString.lowercased()), "expected_revision": .number(Double(revision)),
        "profile": .string(session.profile),
        "pinned": pinned.map(JSONValue.bool), "unread": unread.map(JSONValue.bool), "title": title.map(JSONValue.string),
        "archived": archived.map(JSONValue.bool),
      ])
    }
    do {
      try await http.json("PATCH", "/api/sessions/\(session.id)", body: body(revision: session.revision))
    } catch HermesError.http(status: 409, _) {
      // The row moved on since the sidebar was read: fetch its current revision and try once more.
      let current = try await http.json("GET", "/api/sessions/\(session.id)", query: [("profile", session.profile)])
      try await http.json("PATCH", "/api/sessions/\(session.id)", body: body(revision: current["runtime_revision"].int ?? 0))
    }
  }

  // MARK: Server requests

  /// Answers a question. One the gateway put to every viewer (`ServerRequest.isPrompt`) is
  /// answered by name, and settles it on the desktop too; any other is a JSON-RPC answer.
  public func answer(_ request: ServerRequest, result: JSONValue, profile: String) async {
    guard request.isPrompt else {
      await rpc.respond(to: request, result: result)
      return
    }
    var params: [String: JSONValue] = [
      "session_id": .string(request.sessionID), "profile": .string(profile),
      "prompt_id": request.params["prompt_id"], "execution_generation": request.params["execution_generation"],
    ]
    let method: String
    if request.method == "clarify" {
      method = "clarify.respond"
      params["answer"] = .string(Self.clarifyAnswer(result, promptID: request.params["prompt_id"].stringValue))
    } else {
      method = "approval.respond"
      params["choice"] = .string(result["choice"].string ?? "deny")
    }
    _ = try? await rpc.call(method, .object(params), timeout: 30)
  }

  /// Declines a question: a prompt is answered with nothing (clarify: skipped; approval: denied).
  public func decline(_ request: ServerRequest, profile: String, message: String = "cancelled") async {
    if request.isPrompt {
      await answer(request, result: request.method == "clarify" ? ["answers": [:]] : ["choice": "deny"], profile: profile)
    } else {
      await rpc.reject(request, code: -32000, message: message)
    }
  }

  /// The text `clarify.respond` takes for the app's `{answers: {qid: value}}`: the picked choice,
  /// several joined with commas, or empty for a skipped question.
  static func clarifyAnswer(_ result: JSONValue, promptID: String) -> String {
    let value = result["answers"][promptID]
    if let text = value.string { return text }
    if let values = value.array { return values.compactMap(\.string).joined(separator: ", ") }
    return ""
  }
}

/// A picture staged on the Mac for the next turn (`HermesClient.attachImage`).
public struct StagedImage: Sendable, Equatable {
  public let path: String
  public let mime: String
}
