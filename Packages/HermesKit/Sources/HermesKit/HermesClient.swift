import Foundation

/// What `session.resume`, `session.create` and `session.branch_stored` hand back.
public struct LiveSession: Sendable {
  /// Short id of the running session; events are addressed to it.
  public let liveID: String
  /// Id of the stored conversation the sidebar lists.
  public let storedID: String
  public let messages: [JSONValue]
  public let inflight: JSONValue
  public let openRequests: [ServerRequest]
  public let info: JSONValue
  /// A turn is running in this session right now (thinking, running a tool, or streaming).
  public let isRunning: Bool
  /// When that turn started, seconds since 1970.
  public let turnStartedAt: Double?

  init(json: JSONValue, fallbackStoredID: String = "") {
    liveID = json["session_id"].string ?? fallbackStoredID
    storedID = json["stored_session_id"].string ?? (fallbackStoredID.isEmpty ? json["session_id"].stringValue : fallbackStoredID)
    messages = json["messages"].array ?? []
    inflight = json["inflight"]
    info = json["info"]
    let status = json["status"].stringValue
    isRunning = json["running"].truthy || ["working", "streaming", "waiting"].contains(status)
    turnStartedAt = json["turn_started_at"].double
    openRequests = (json["open_requests"].array ?? []).compactMap { item in
      guard let method = item["method"].string, !item["id"].isNull else { return nil }
      return ServerRequest(rawID: item["id"], method: method, params: item["params"])
    }
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

  public init(endpoint: ServerEndpoint, cookies: any SessionCookieStore) {
    self.endpoint = endpoint
    http = HermesHTTP(endpoint: endpoint, cookies: cookies)
    rpc = RPCConnection(endpoint: endpoint, cookies: cookies)
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
    return (json["profiles"].array ?? []).map(Profile.init(json:)).filter { !$0.name.isEmpty }
  }

  /// PNG/JPEG bytes of a profile's avatar, when it has one.
  public func avatar(profile: String) async throws -> Data? {
    let json = try await rpc.call("profiles.get_asset", ["name": .string(profile), "asset": "avatar"], timeout: 30)
    guard json["found"].truthy, let dataURL = json["data"].string, let comma = dataURL.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
  }

  /// Chats another Hermes process on the Mac holds right now, keyed by stored session id.
  public func owners() async throws -> [String: ChatOwner] {
    let json = try await http.json("GET", "/hd/owners", timeout: 10)
    var out: [String: ChatOwner] = [:]
    for item in json["owners"].array ?? [] {
      let owner = ChatOwner(json: item)
      if !owner.sessionID.isEmpty { out[owner.sessionID] = owner }
    }
    return out
  }

  public func status() async throws -> JSONValue {
    try await http.json("GET", "/api/status", timeout: 15)
  }

  // MARK: Opening conversations

  /// Binds a stored conversation to a live session and returns its transcript.
  /// `lazy` re-attaches a session that is still live but refuses (4007) to build a new one.
  /// `omitMessages` leaves the transcript out (a long chat's runs to megabytes): read it a page
  /// at a time with `historyPage` instead, as the desktop app does.
  public func resume(storedID: String, profile: String, lazy: Bool = false, omitMessages: Bool = false) async throws -> LiveSession {
    let params = JSONValue.fields([
      "session_id": .string(storedID), "profile": .string(profile), "cols": 100, "lazy": lazy ? true : nil,
      "omit_messages": omitMessages ? true : nil, "inline_images": false,
    ])
    return LiveSession(json: try await rpc.call("session.resume", params, timeout: 90), fallbackStoredID: storedID)
  }

  public func create(profile: String, options: NewSessionOptions = NewSessionOptions()) async throws -> LiveSession {
    let hasModel = !(options.model ?? "").isEmpty
    let hasCwd = !(options.cwd ?? "").isEmpty
    let params = JSONValue.fields([
      "profile": .string(profile), "cols": 100,
      "title": options.title.flatMap { $0.isEmpty ? nil : .string($0) },
      "model": hasModel ? options.model.map(JSONValue.string) : nil,
      "provider": hasModel ? options.provider.flatMap { $0.isEmpty ? nil : .string($0) } : nil,
      "reasoning_effort": options.reasoningEffort.flatMap { $0.isEmpty ? nil : .string($0) },
      "cwd": hasCwd ? options.cwd.map(JSONValue.string) : nil,
      "cwd_explicit": hasCwd ? true : nil,
    ])
    return LiveSession(json: try await rpc.call("session.create", params, timeout: 90))
  }

  /// Copies a whole stored conversation into a new one this client owns. Used to continue
  /// a chat that another Hermes process holds, or a messaging thread.
  public func branch(storedID: String, profile: String, cwd: String, model: String, provider: String) async throws -> LiveSession {
    func params(withModel: Bool) -> JSONValue {
      JSONValue.fields([
        "parent_session_id": .string(storedID), "profile": .string(profile), "cols": 100,
        "cwd": cwd.isEmpty ? nil : .string(cwd), "cwd_explicit": cwd.isEmpty ? nil : true,
        "model": withModel ? .string(model) : nil, "provider": withModel ? .string(provider) : nil,
      ])
    }
    // Without the model the copy gets the backend's process-wide default, so try with it first.
    let keepModel = !model.isEmpty && !provider.isEmpty
    do {
      return LiveSession(json: try await rpc.call("session.branch_stored", params(withModel: keepModel), timeout: 90))
    } catch where keepModel {
      return LiveSession(json: try await rpc.call("session.branch_stored", params(withModel: false), timeout: 90))
    }
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

  public func activeSessions() async throws -> [JSONValue] {
    try await rpc.call("session.active_list", [:], timeout: 15)["sessions"].array ?? []
  }

  public func close(liveID: String) async throws {
    _ = try await rpc.call("session.close", ["session_id": .string(liveID)], timeout: 15)
  }

  // MARK: Turns

  /// Sends a user turn. Returns the backend's status (`queued` when a reply is already running).
  /// `queued` marks a message that waited for the reply before it: should that reply still be
  /// settling on the Mac, the backend queues it instead of cutting into the reply.
  @discardableResult
  public func submit(liveID: String, profile: String, text: String, queued: Bool = false) async throws -> String {
    var params: [String: JSONValue] = [
      "session_id": .string(liveID), "profile": .string(profile), "text": .string(text), "surface": "chat",
    ]
    if queued { params["queued"] = true }
    let result = try await rpc.call("prompt.submit", .object(params), timeout: 60)
    return result["status"].stringValue
  }

  /// Hands a message to the running reply: the agent takes it in now and answers it (the model
  /// call in flight restarts with it, or it waits for the step that is running). Answers
  /// `redirected`, `queued` (the reply was still starting; it goes out next), or `rejected`.
  public func redirect(liveID: String, profile: String, text: String) async throws -> String {
    let result = try await rpc.call(
      "session.redirect", ["session_id": .string(liveID), "profile": .string(profile), "text": .string(text)], timeout: 30)
    return result["status"].stringValue
  }

  public func interrupt(liveID: String, profile: String) async throws {
    _ = try await rpc.call("session.interrupt", ["session_id": .string(liveID), "profile": .string(profile)], timeout: 30)
  }

  /// Queues an image for the next turn of this session.
  public func attachImage(liveID: String, profile: String, data: Data, filename: String) async throws {
    let result = try await rpc.call(
      "image.attach_bytes",
      ["session_id": .string(liveID), "profile": .string(profile), "content_base64": .string(data.base64EncodedString()),
       "filename": .string(filename)], timeout: 240)
    guard result["attached"].truthy else {
      throw HermesError.invalidResponse(result["message"].string ?? "\(filename) was not accepted")
    }
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

  public func setModel(liveID: String, profile: String, model: String, provider: String, confirmed: Bool = false) async throws -> ModelSwitchResult {
    let params = JSONValue.fields([
      "session_id": .string(liveID), "profile": .string(profile), "key": "model",
      "value": .string("\(model) --provider \(provider) --session"),
      "confirm_expensive_model": confirmed ? true : nil,
    ])
    let json = try await rpc.call("config.set", params, timeout: 60)
    return ModelSwitchResult(
      model: json["value"].string ?? model, needsConfirmation: json["confirm_required"].truthy,
      confirmationMessage: json["confirm_message"].stringValue, isDeferred: json["deferred"].truthy,
      warning: json["warning"].stringValue)
  }

  /// Returns the effort the backend settled on.
  public func setReasoningEffort(liveID: String, profile: String, effort: String) async throws -> String {
    let json = try await rpc.call(
      "config.set", ["session_id": .string(liveID), "profile": .string(profile), "key": "reasoning", "value": .string(effort)],
      timeout: 30)
    return json["value"].string ?? effort
  }

  // MARK: Conversation metadata

  public func setArchived(storedID: String, profile: String, archived: Bool) async throws {
    _ = try await rpc.call(
      "session.archive", ["session_id": .string(storedID), "profile": .string(profile), "archived": .bool(archived)], timeout: 30)
  }

  /// Renames through the live session (a title set before the row exists is queued by the backend).
  public func setTitle(liveID: String, profile: String, title: String) async throws {
    _ = try await rpc.call(
      "session.title", ["session_id": .string(liveID), "profile": .string(profile), "title": .string(title)], timeout: 30)
  }

  /// Pin, unread and title changes on a stored row. The backend fences these writes: each must
  /// carry a fresh request id and the revision it was based on, or it answers 409.
  public func update(_ session: SessionSummary, pinned: Bool? = nil, unread: Bool? = nil, title: String? = nil) async throws {
    func body(revision: Int) -> JSONValue {
      JSONValue.fields([
        "request_id": .string(UUID().uuidString.lowercased()), "expected_revision": .number(Double(revision)),
        "profile": .string(session.profile),
        "pinned": pinned.map(JSONValue.bool), "unread": unread.map(JSONValue.bool), "title": title.map(JSONValue.string),
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

  public func answer(_ request: ServerRequest, result: JSONValue) async {
    await rpc.respond(to: request, result: result)
  }

  public func decline(_ request: ServerRequest, message: String = "cancelled") async {
    await rpc.reject(request, code: -32000, message: message)
  }
}
