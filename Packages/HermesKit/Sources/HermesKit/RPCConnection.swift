import Foundation

public enum ConnectionState: Sendable, Equatable {
  case idle
  case connecting
  /// The gateway said hello and accepted our capabilities; calls can flow.
  case open
  /// Dropped; a retry is scheduled. Carries the transport's reason when there is one.
  case closed(String?)
  /// The gate refused the session cookie. No retry until the user signs in again.
  case unauthorized
}

/// A broadcast from the gateway. `sessionID` is the *live* session id, or empty for global events.
public struct GatewayEvent: Sendable, Equatable {
  public let type: String
  public let sessionID: String
  public let payload: JSONValue
}

/// A question the gateway asks the client (approval, clarify, sudo, secret) and waits on.
public struct ServerRequest: Sendable, Equatable, Identifiable {
  /// JSON-RPC id exactly as sent, echoed back in the answer.
  public let rawID: JSONValue
  public let method: String
  public let params: JSONValue

  public var id: String { rawID.scalarText ?? rawID.text() }
  public var sessionID: String { params["session_id"].stringValue }

  public init(rawID: JSONValue, method: String, params: JSONValue) {
    self.rawID = rawID
    self.method = method
    self.params = params
  }

  static let promptPrefix = "prompt:"

  /// A question the gateway put to every viewer of a chat (`clarify.request`, `approval.request`),
  /// in the shape the app's question cards take. Whoever answers first settles it for all of them,
  /// the desktop app included; it is answered with `clarify.respond` / `approval.respond`, not with a
  /// JSON-RPC result.
  public static func prompt(kind: String, sessionID: String, payload: JSONValue) -> ServerRequest? {
    guard kind == "clarify" || kind == "approval", let promptID = payload["prompt_id"].scalarText, !promptID.isEmpty else {
      return nil
    }
    var params: [String: JSONValue] = [
      "session_id": .string(sessionID), "prompt_id": .string(promptID),
      "execution_generation": payload["execution_generation"],
    ]
    let choices = payload["choices"].isNull ? JSONValue.array([]) : payload["choices"]
    if kind == "clarify" {
      params["questions"] = .array([
        [
          "qid": .string(promptID), "question": payload["question"], "choices": choices,
          "multi_select": .bool(payload["multi_select"].truthy),
        ]
      ])
    } else {
      params["command"] = payload["command"]
      params["description"] = payload["description"]
      params["choices"] = choices
      params["allow_permanent"] = .bool((choices.array ?? []).contains(.string("always")))
      params["edit"] = payload["edit"]
    }
    return ServerRequest(rawID: .string("\(promptPrefix)\(kind):\(promptID)"), method: kind, params: .object(params))
  }

  /// The id `prompt(kind:sessionID:payload:)` gives the question with this prompt id.
  public static func promptRequestID(kind: String, promptID: String) -> String { "\(promptPrefix)\(kind):\(promptID)" }

  /// Asked by the gateway of every viewer, rather than of this socket alone.
  public var isPrompt: Bool { rawID.string?.hasPrefix(Self.promptPrefix) == true }
}

/// What the gateway fences a chat's changes with. A change names the revision and the turn
/// generation it was based on, and is refused (`revision_conflict`, `stale_generation`) when the
/// chat moved on meanwhile.
public struct SessionFences: Sendable, Equatable {
  public var revision: Int?
  public var generation: Int?
}

/// JSON-RPC over the Hermes gateway's WebSocket (`/hd/gateway/ws` on the gate), with reconnect.
///
/// Wire notes, verified against the gateway that ships with the Nov 2026 desktop app:
/// - The socket speaks `hermes-gateway-v1`; the gate adds the one-use ticket.
/// - One WebSocket message can carry several JSON lines.
/// - After `gateway.ready` the client calls `client.capabilities {server_requests: true}`, or the
///   gateway fails its sudo and secret requests at once.
/// - A socket only reaches chats it opened (`session.create` / `session.resume`): after a
///   reconnect every chat answers `permission_denied` until it is resumed again.
/// - Every viewer of a chat gets every event of its turns, whoever started them, and its
///   questions arrive as `clarify.request` / `approval.request` events (`ServerRequest.prompt`).
public actor RPCConnection {
  public enum Incoming: Sendable {
    case state(ConnectionState)
    case event(GatewayEvent)
    case request(ServerRequest)
  }

  /// Single-consumer stream of everything the gateway pushes.
  public nonisolated let incoming: AsyncStream<Incoming>
  private let continuation: AsyncStream<Incoming>.Continuation

  private let endpoint: ServerEndpoint
  private let cookies: any SessionCookieStore
  private let session: URLSession

  private struct Pending {
    let continuation: CheckedContinuation<JSONValue, any Error>
    let timeout: Task<Void, Never>
    let sessionID: String
  }

  public private(set) var state: ConnectionState = .idle
  private var socket: URLSessionWebSocketTask?
  private var loop: Task<Void, Never>?
  private var generation = 0
  private var pending: [String: Pending] = [:]
  private var nextID = 0
  private var isReady = false
  private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var backoff: Double = RPCConnection.initialBackoff
  private var sleeper: Task<Void, Never>?
  /// Per chat, the newest revision and turn generation the gateway has named.
  private var fences: [String: SessionFences] = [:]

  private static let initialBackoff = 0.8
  private static let maxBackoff = 8.0
  private static let maxMessageBytes = 64 << 20
  static let protocolName = "hermes-gateway-v1"

  public init(endpoint: ServerEndpoint, cookies: any SessionCookieStore) {
    self.endpoint = endpoint
    self.cookies = cookies
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: configuration)
    (incoming, continuation) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .unbounded)
  }

  deinit {
    continuation.finish()
    session.invalidateAndCancel()
  }

  // MARK: Lifecycle

  /// Connects and keeps the connection up until `stop()`.
  public func start() {
    if loop != nil {
      kick()
      return
    }
    generation += 1
    let current = generation
    // Leave `.unauthorized`/`.idle` right away so a caller that waits for readiness next does not read the old state.
    setState(.connecting)
    loop = Task { [weak self] in await self?.run(generation: current) }
  }

  public func stop() {
    generation += 1
    loop?.cancel()
    loop = nil
    sleeper?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    isReady = false
    failAll(HermesError.notConnected)
    setState(.idle)
  }

  /// The phone woke up or the network came back: skip the rest of the backoff.
  public func kick() {
    backoff = Self.initialBackoff
    sleeper?.cancel()
    if loop == nil { start() }
  }

  public var isOpen: Bool { state == .open }

  /// Suspends until the gateway is ready, or throws after `timeout` seconds.
  public func waitUntilReady(timeout: Double = 45) async throws {
    if state == .open { return }
    if state == .unauthorized { throw HermesError.loginRequired }
    let key = UUID()
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(timeout))
      guard !Task.isCancelled else { return }
      await self?.expireWaiter(key)
    }
    defer { expiry.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      readyWaiters[key] = continuation
    }
  }

  private func expireWaiter(_ key: UUID) {
    readyWaiters.removeValue(forKey: key)?.resume(throwing: HermesError.timedOut("Connecting to the Mac"))
  }

  private func resumeWaiters(_ result: Result<Void, any Error>) {
    let waiters = readyWaiters
    readyWaiters.removeAll()
    for waiter in waiters.values { waiter.resume(with: result) }
  }

  private func setState(_ next: ConnectionState) {
    guard state != next else { return }
    state = next
    continuation.yield(.state(next))
  }

  // MARK: Connection loop

  private func makeRequest() -> URLRequest {
    var request = URLRequest(url: endpoint.webSocketURL, timeoutInterval: 30)
    request.httpShouldHandleCookies = false
    request.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
    request.setValue(Self.protocolName, forHTTPHeaderField: "Sec-WebSocket-Protocol")
    if let cookie = cookies.cookie(for: endpoint) {
      request.setValue("\(HermesHTTP.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
    }
    return request
  }

  private func run(generation current: Int) async {
    while !Task.isCancelled, current == generation {
      setState(.connecting)
      let task = session.webSocketTask(with: makeRequest())
      task.maximumMessageSize = Self.maxMessageBytes
      socket = task
      task.resume()
      let pinger = Task.detached { await Self.keepAlive(task) }

      var failure: String?
      do {
        while true {
          switch try await task.receive() {
          case .string(let text): handle(text)
          case .data(let data): handle(String(decoding: data, as: UTF8.self))
          @unknown default: break
          }
        }
      } catch {
        failure = (error as NSError).localizedDescription
      }
      pinger.cancel()

      let status = (task.response as? HTTPURLResponse)?.statusCode
      task.cancel(with: .goingAway, reason: nil)
      guard current == generation else { return }
      socket = nil
      isReady = false
      failAll(HermesError.notConnected)
      if Task.isCancelled { return }

      if status == 401 || status == 403 {
        loop = nil
        setState(.unauthorized)
        resumeWaiters(.failure(HermesError.loginRequired))
        return
      }
      setState(.closed(failure))
      await sleepBackoff()
    }
  }

  private func sleepBackoff() async {
    let delay = backoff
    backoff = min(backoff * 1.7, Self.maxBackoff)
    let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(delay)) }
    sleeper = nap
    await nap.value
    sleeper = nil
  }

  /// Pings so a dead path (sleeping phone, dropped tunnel) surfaces as a receive error instead of silence.
  private static func keepAlive(_ task: URLSessionWebSocketTask) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(25))
      if Task.isCancelled { return }
      let alive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = Once()
        task.sendPing { error in
          if once.claim() { continuation.resume(returning: error == nil) }
        }
      }
      if !alive {
        task.cancel(with: .abnormalClosure, reason: nil)
        return
      }
    }
  }

  // MARK: Frames

  private func handle(_ text: String) {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let frame = try? JSONValue.parse(String(line)) else { continue }
      let id = frame["id"]
      let method = frame["method"].string

      if !id.isNull, method == nil {
        guard let key = id.scalarText, let waiting = pending.removeValue(forKey: key) else { continue }
        waiting.timeout.cancel()
        let error = frame["error"]
        if error.isNull {
          let result = frame["result"]
          noteFences(result["session_id"].string ?? waiting.sessionID, from: result)
          waiting.continuation.resume(returning: result)
        } else {
          // A fence refusal names the chat's current revision and generation: the retry uses them.
          noteFences(waiting.sessionID, from: error["data"])
          waiting.continuation.resume(throwing: HermesError.rpc(
            code: error["code"].int ?? 0,
            message: error["message"].string ?? "The Mac refused the request.",
            reason: error["data"]["reason"].string))
        }
        continue
      }

      if method == "event" {
        let params = frame["params"]
        let type = params["type"].stringValue
        let sessionID = params["session_id"].stringValue
        let payload = params["payload"]
        if type == "gateway.ready" { gatewayReady() }
        if !sessionID.isEmpty {
          noteFences(sessionID, generation: params["execution_generation"].int ?? payload["execution_generation"].int)
          if type == "session.info" || type == "session.updated" { noteFences(sessionID, revision: payload["revision"].int) }
        }
        switch type {
        case "clarify.request", "approval.request":
          if let request = ServerRequest.prompt(kind: String(type.prefix { $0 != "." }), sessionID: sessionID, payload: payload) {
            continuation.yield(.request(request))
          }
          continue
        case "clarify.settled", "approval.settled":
          // Answered here, on the desktop, or given up on: every copy of the question goes.
          guard let promptID = payload["prompt_id"].scalarText else { continue }
          let requestID = ServerRequest.promptRequestID(kind: String(type.prefix { $0 != "." }), promptID: promptID)
          continuation.yield(.event(GatewayEvent(type: "prompt.settled", sessionID: sessionID, payload: ["id": .string(requestID)])))
          continue
        default:
          break
        }
        continuation.yield(.event(GatewayEvent(type: type, sessionID: sessionID, payload: payload)))
        continue
      }

      if let method, !id.isNull {
        continuation.yield(.request(ServerRequest(rawID: id, method: method, params: frame["params"])))
      }
    }
  }

  // MARK: Fences

  /// The newest revision and turn generation the gateway named for a chat.
  public func fences(for sessionID: String) -> SessionFences {
    fences[sessionID] ?? SessionFences()
  }

  /// Records fences from a snapshot, a receipt or a refusal. They only move forward: an older
  /// answer that arrives late never takes the chat back.
  public func noteFences(_ sessionID: String, from json: JSONValue) {
    noteFences(sessionID, revision: json["revision"].int, generation: json["execution_generation"].int)
  }

  func noteFences(_ sessionID: String, revision: Int? = nil, generation: Int? = nil) {
    guard !sessionID.isEmpty, revision != nil || generation != nil else { return }
    var current = fences[sessionID] ?? SessionFences()
    if let revision { current.revision = max(current.revision ?? revision, revision) }
    if let generation { current.generation = max(current.generation ?? generation, generation) }
    fences[sessionID] = current
  }

  /// One-time tokens the gateway gave with a "this model costs more" question, by chat and model.
  private var confirmations: [String: String] = [:]

  func rememberConfirmation(_ key: String, token: String) { confirmations[key] = token }

  func takeConfirmation(_ key: String) -> String? { confirmations.removeValue(forKey: key) }

  private func gatewayReady() {
    isReady = true
    backoff = Self.initialBackoff
    let current = generation
    Task { [weak self] in await self?.announceCapabilities(generation: current) }
  }

  private func announceCapabilities(generation current: Int) async {
    _ = try? await call("client.capabilities", ["server_requests": true], timeout: 20)
    guard current == generation, isReady else { return }
    setState(.open)
    resumeWaiters(.success(()))
  }

  // MARK: Calls

  /// Sends a request and waits for its answer.
  public func call(_ method: String, _ params: JSONValue = .object([:]), timeout: Double = 120) async throws -> JSONValue {
    guard let socket else { throw HermesError.notConnected }
    nextID += 1
    let id = String(nextID)
    let frame: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
    let text = frame.text()
    let sessionID = params["session_id"].stringValue
    return try await withCheckedThrowingContinuation { continuation in
      let expiry = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard !Task.isCancelled else { return }
        await self?.settle(id, with: .failure(HermesError.timedOut(method)))
      }
      pending[id] = Pending(continuation: continuation, timeout: expiry, sessionID: sessionID)
      socket.send(.string(text)) { [weak self] error in
        guard error != nil else { return }
        Task { await self?.settle(id, with: .failure(HermesError.notConnected)) }
      }
    }
  }

  private func settle(_ id: String, with result: Result<JSONValue, any Error>) {
    guard let waiting = pending.removeValue(forKey: id) else { return }
    waiting.timeout.cancel()
    waiting.continuation.resume(with: result)
  }

  private func failAll(_ error: any Error) {
    let waiting = pending
    pending.removeAll()
    for item in waiting.values {
      item.timeout.cancel()
      item.continuation.resume(throwing: error)
    }
  }

  // MARK: Answers to server requests

  public func respond(to request: ServerRequest, result: JSONValue) {
    send(["jsonrpc": "2.0", "id": request.rawID, "result": result])
  }

  public func reject(_ request: ServerRequest, code: Int = -32601, message: String = "not implemented") {
    send(["jsonrpc": "2.0", "id": request.rawID, "error": ["code": .number(Double(code)), "message": .string(message)]])
  }

  private func send(_ frame: JSONValue) {
    socket?.send(.string(frame.text())) { _ in }
  }
}

/// `sendPing` has been seen to call its handler more than once when a connection dies mid-ping.
private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      if claimed { return false }
      claimed = true
      return true
    }
  }
}
