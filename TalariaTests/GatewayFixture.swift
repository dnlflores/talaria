import CryptoKit
import Foundation
import HermesKit
import Network

/// A stand-in for the Hermes gateway on loopback, for tests that drive the production `ChatModel`
/// and `HermesClient` with no Mac: the HTTP the app reads (`/api/status`, stored messages) and the
/// JSON-RPC WebSocket (`/api/ws`, protocol `hermes-gateway-v1`). Tests script how slash commands
/// answer, can hold an answer back, and read what was submitted.
final class GatewayFixture: @unchecked Sendable {
  struct Prompt: Equatable, Sendable {
    let session: String
    let text: String
    let queued: Bool
  }

  /// How the fixture answers a call: a result, or a JSON-RPC error (with the gateway's typed
  /// `data.reason` when it has one).
  enum Answer: Sendable {
    case result(JSONValue)
    case error(code: Int, message: String)
    case refusal(code: Int, message: String, data: JSONValue)
  }

  /// A `session.mutate` that arrived.
  struct Mutation: Equatable, Sendable {
    let session: String
    let requestID: String
    let operation: String
    let target: Int?
  }

  private let queue = DispatchQueue(label: "talaria.tests.gateway-fixture")
  private let lock = NSLock()
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: Connection] = [:]

  // Guarded by `lock`.
  private var prompts: [Prompt] = []
  private var slashCalls: [String] = []
  private var isHolding = false
  private var held: [@Sendable () -> Void] = []
  private var execAnswer: @Sendable (String) -> Answer = { _ in .result(["output": "ok"]) }
  private var dispatchAnswer: @Sendable (String, String) -> Answer = { name, _ in
    .error(code: 4018, message: "not a quick/plugin/bundle/skill command: \(name)")
  }
  /// Chats whose reply is running when they are opened.
  private var running: Set<String> = []
  /// How `prompt.submit` answers: nil accepts the message.
  private var submitAnswer: @Sendable (String) -> Answer? = { _ in nil }
  private var isHoldingSubmits = false
  private var submitCalls = 0
  /// The Mac's copy of each chat: stored rows with durable ids, as the gateway lists them.
  private var transcripts: [String: [JSONValue]] = [:]
  private var nextRowID = 1
  private var revisions: [String: Int] = [:]
  private var generations: [String: Int] = [:]
  /// Rewind receipts by request id: an exact retry gets the receipt already written.
  private var receipts: [String: JSONValue] = [:]
  private var mutations: [Mutation] = []
  /// The next rewind is applied, then the socket drops before its answer goes out.
  private var dropsNextMutateAnswer = false
  /// The next `session.mutate` is applied, but its answer waits until `release()`.
  private var holdsNextMutateAnswer = false
  /// The next `session.resume` with `omit_messages` (a reattach) waits until `release()`.
  private var holdsNextReattach = false
  private var heldReattaches = 0
  /// Another device moves the chat on between the snapshot and the next rewind.
  private var movesOnBeforeNextMutate = false
  /// Every JSON-RPC method called, in order.
  private var methodCalls: [String] = []
  /// `/api/status` asks for a sign-in (the app stays off its inbox and its event pump).
  private var signInRequired = true
  /// `prompt.btw`/`prompt.background` emit this completion text before answering with the task id.
  private var sideAnswerFirst: String?
  private var refusesResumes = false
  /// Chats another process is running: their row carries a fresh heartbeat the gateway's live list lacks.
  private var elsewhere: Set<String> = []
  private var sideCount = 0
  /// Stored-message reads answer 503 while this is set.
  private var failsHistory = false
  /// Seconds each stored-message read waits before it answers.
  private var historyDelay = 0.0
  private var historyReads = 0

  private(set) var port: UInt16 = 0
  var address: String { "http://127.0.0.1:\(port)" }

  func start() async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let once = OnceFlag()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.claim() { continuation.resume() }
        case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
    port = listener.port?.rawValue ?? 0
  }

  func stop() {
    listener?.cancel()
    queue.async { [self] in
      for connection in connections.values { connection.connection.cancel() }
      connections = [:]
    }
  }

  // MARK: Scripting

  func answerExec(_ answer: @escaping @Sendable (String) -> Answer) { locked { execAnswer = answer } }
  func answerDispatch(_ answer: @escaping @Sendable (String, String) -> Answer) { locked { dispatchAnswer = answer } }
  func startsRunning(_ session: String) { locked { _ = running.insert(session) } }
  /// The chat's reply has ended: opening it again finds it idle.
  func finishesRunning(_ session: String) { locked { _ = running.remove(session) } }
  /// Answers `prompt.submit` with an error instead of accepting it (nil accepts).
  func answerSubmit(_ answer: @escaping @Sendable (String) -> Answer?) { locked { submitAnswer = answer } }
  /// `prompt.submit` answers wait until `release()`.
  func holdSubmits() { locked { isHoldingSubmits = true } }
  /// Signed in already: the app reaches Ready and runs its real event pump.
  func opensWithoutSignIn() { locked { signInRequired = false } }
  /// A side agent that finishes (with `text`) before the gateway answers with its task id.
  func sideAnswersBeforeTaskID(_ text: String) { locked { sideAnswerFirst = text } }
  /// `session.resume` fails, so a chat opens read-only from its stored history.
  func refuseResumes() { locked { refusesResumes = true } }
  /// Another process runs the chat: the app watches it instead of attaching.
  func runsElsewhere(_ session: String) { locked { _ = elsewhere.insert(session) } }
  /// Every JSON-RPC method called, in order.
  var calls: [String] { locked { methodCalls } }

  /// Slash answers wait until `release()`.
  func hold() { locked { isHolding = true } }

  func release() {
    let waiting: [@Sendable () -> Void] = locked {
      isHolding = false
      isHoldingSubmits = false
      defer { held = [] }
      return held
    }
    for answer in waiting { answer() }
  }

  /// Messages the fixture accepted.
  var submitted: [Prompt] { locked { prompts } }
  /// Every `prompt.submit` that arrived, accepted or not.
  var submitAttempts: Int { locked { submitCalls } }
  /// `slash.exec` commands and `command.dispatch` names, in the order they arrived.
  var slashRequests: [String] { locked { slashCalls } }
  /// Every `session.mutate`, in the order it arrived.
  var mutateRequests: [Mutation] { locked { mutations } }

  /// The Mac's copy of a chat as (role, words), oldest first.
  func transcript(_ session: String) -> [(role: String, text: String)] {
    locked { (transcripts[session] ?? []).map { ($0["role"].stringValue, $0["content"].stringValue) } }
  }

  /// Rows already stored when the chat opens.
  func seed(_ session: String, _ rows: [(role: String, content: JSONValue)]) {
    locked { for row in rows { append(row.role, row.content, to: session) } }
  }

  /// The reply to the running turn is stored (deliver it to the chat with `handle`).
  func reply(_ session: String, _ text: String) {
    locked { append("assistant", .string(text), to: session) }
  }

  /// Another device sent a message and got a reply, with no event reaching this app.
  func sendFromAnotherDevice(_ session: String, _ text: String, reply: String) {
    locked {
      append("user", .string(text), to: session)
      append("assistant", .string(reply), to: session)
      generations[session, default: 1] += 1
    }
  }

  func dropNextMutateAnswer() { locked { dropsNextMutateAnswer = true } }
  func holdNextMutateAnswer() { locked { holdsNextMutateAnswer = true } }
  func holdNextReattach() { locked { holdsNextReattach = true } }
  /// Reattaches held by `holdNextReattach` so far.
  var reattachesHeld: Int { locked { heldReattaches } }
  func moveOnBeforeNextMutate() { locked { movesOnBeforeNextMutate = true } }
  /// Stored-message reads fail (503) until this is called with false.
  func failHistory(_ fails: Bool) { locked { failsHistory = fails } }
  /// Each stored-message read waits `seconds` before answering.
  func delayHistory(_ seconds: Double) { locked { historyDelay = seconds } }
  /// Stored-message reads so far.
  var historyReadCount: Int { locked { historyReads } }

  /// Call with `lock` held.
  private func append(_ role: String, _ content: JSONValue, to session: String) {
    let id = nextRowID
    nextRowID += 1
    transcripts[session, default: []].append([
      "id": .number(Double(id)), "row_id": .number(Double(id)), "role": .string(role), "content": content,
      "timestamp": .number(Date().timeIntervalSince1970),
    ])
  }

  /// Waits until `condition` holds, up to `timeout` seconds.
  func wait(_ timeout: Double = 5, until condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// Sends a gateway event to every open socket (`message.complete` ends a reply).
  func emit(_ type: String, session: String, payload: JSONValue = [:]) {
    let frame: JSONValue = [
      "jsonrpc": "2.0", "method": "event",
      "params": ["type": .string(type), "session_id": .string(session), "payload": payload],
    ]
    queue.async {
      for connection in self.connections.values where connection.isSocket { connection.send(frame) }
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  // MARK: Connections

  private func accept(_ nw: NWConnection) {
    let connection = Connection(connection: nw)
    connection.onRequest = { [weak self, weak connection] request in
      guard let self, let connection else { return }
      self.respond(to: request, on: connection)
    }
    connection.onMessage = { [weak self, weak connection] text in
      guard let self, let connection else { return }
      for line in text.split(separator: "\n") {
        guard let call = try? JSONValue.parse(String(line)) else { continue }
        self.reply(to: call, on: connection)
      }
    }
    connection.onClose = { [weak self, weak connection] in
      guard let self, let connection else { return }
      self.connections[ObjectIdentifier(connection)] = nil
    }
    connections[ObjectIdentifier(connection)] = connection
    connection.start(on: queue)
  }

  private func respond(to request: Connection.Request, on connection: Connection) {
    if request.path == "/api/ws" {
      connection.upgrade(key: request.headers["sec-websocket-key"] ?? "")
      connection.send(["jsonrpc": "2.0", "method": "event", "params": ["type": "gateway.ready", "payload": [:]]])
      return
    }
    let body: JSONValue
    switch request.path {
    case "/api/status":
      // By default sign-in is offered but not done: the app stays off its inbox and the test drives the chat.
      body = [
        "auth_required": .bool(locked { signInRequired }), "auth_providers": ["nous"], "gateway_running": true,
        "version": "fixture",
      ]
    case let path where path.hasPrefix("/api/sessions/") && path.hasSuffix("/messages"):
      let session = String(path.dropFirst("/api/sessions/".count).dropLast("/messages".count))
      let (rows, failing, delay): ([JSONValue], Bool, Double) = locked {
        historyReads += 1
        return (transcripts[session] ?? [], failsHistory, historyDelay)
      }
      if failing {
        connection.respond(["error": "history unavailable"], status: 503)
        return
      }
      // A page of the newest rows: `limit` rows `offset` back from the newest (`order=latest`).
      if let limit = request.query["limit"].flatMap(Int.init) {
        let offset = request.query["offset"].flatMap(Int.init) ?? 0
        let end = max(0, rows.count - offset)
        let start = max(0, end - limit)
        body = [
          "messages": .array(Array(rows[start..<end])), "total": .number(Double(rows.count)), "has_more": .bool(start > 0),
        ]
      } else {
        body = ["messages": .array(rows), "total": .number(Double(rows.count)), "has_more": false]
      }
      if delay > 0 {
        queue.asyncAfter(deadline: .now() + delay) { connection.respond(body) }
        return
      }
    case let path where path.hasPrefix("/api/sessions/") && !path.dropFirst("/api/sessions/".count).contains("/"):
      let session = String(path.dropFirst("/api/sessions/".count))
      let busy = locked { elsewhere.contains(session) }
      body = [
        "id": .string(session), "profile": "preview",
        "last_activity_description": .string(busy ? "Running a command" : ""),
        "last_activity_at": .number(busy ? Date().timeIntervalSince1970 : 0),
      ]
    default:
      body = [:]
    }
    connection.respond(body)
  }

  private func reply(to call: JSONValue, on connection: Connection) {
    let id = call["id"]
    let params = call["params"]
    let session = params["session_id"].string ?? params["title"].string ?? "fixture"
    let answer: @Sendable (Answer) -> Void = { [weak connection] answer in
      guard let connection, !id.isNull else { return }
      switch answer {
      case .result(let result): connection.send(["jsonrpc": "2.0", "id": id, "result": result])
      case .error(let code, let message):
        connection.send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
      case .refusal(let code, let message, let data):
        connection.send(["jsonrpc": "2.0", "id": id, "error": [
          "code": .number(Double(code)), "message": .string(message), "data": data,
        ]])
      }
    }
    locked { methodCalls.append(call["method"].stringValue) }
    switch call["method"].stringValue {
    case "session.resume" where locked({ refusesResumes }):
      answer(.error(code: -32603, message: "resume unavailable"))
    case "session.create", "session.resume":
      let (isRunning, rows, revision, generation) = locked {
        (running.contains(session), transcripts[session] ?? [], revisions[session] ?? 1, generations[session] ?? 1)
      }
      let omit = call["method"].stringValue == "session.create" || params["omit_messages"].truthy
      let result: Answer = .result([
        "session_id": .string(session), "stored_session_id": .string(session), "subscription_id": "fixture",
        "running": .bool(isRunning), "messages": omit ? [] : .array(rows),
        "execution_generation": .number(Double(generation)), "revision": .number(Double(revision)),
        "profile": "preview",
      ])
      let holds = locked {
        guard holdsNextReattach, call["method"].stringValue == "session.resume", params["omit_messages"].truthy else {
          return false
        }
        holdsNextReattach = false
        heldReattaches += 1
        held.append { [queue] in queue.async { answer(result) } }
        return true
      }
      if !holds { answer(result) }
    case "session.mutate":
      answerMutate(params, session: session, on: connection, answer: answer)
    case "slash.exec", "command.dispatch":
      let isExec = call["method"].stringValue == "slash.exec"
      let command = isExec ? params["command"].stringValue : params["name"].stringValue
      let arg = params["arg"].stringValue
      let (result, hold): (Answer, Bool) = locked {
        slashCalls.append(command)
        return (isExec ? execAnswer(command) : dispatchAnswer(command, arg), isHolding)
      }
      let send: @Sendable () -> Void = { [queue] in queue.async { answer(result) } }
      if hold { locked { held.append(send) } } else { answer(result) }
    case "prompt.submit":
      let prompt = Prompt(session: session, text: params["text"].stringValue, queued: params["queued"].truthy)
      let (failure, hold): (Answer?, Bool) = locked {
        submitCalls += 1
        return (submitAnswer(prompt.text), isHoldingSubmits)
      }
      let finish: @Sendable () -> Void = { [self] in
        if let failure {
          answer(failure)
        } else {
          locked {
            prompts.append(prompt)
            append("user", .string(prompt.text), to: session)
            generations[session, default: 1] += 1
          }
          answer(.result(["admission_id": .string(UUID().uuidString)]))
        }
      }
      if hold { locked { held.append { [queue] in queue.async(execute: finish) } } } else { finish() }
    case "file.attach":
      answer(.result(["attached": true, "ref_text": .string("@file:/fixture/\(params["name"].stringValue)")]))
    case "prompt.btw", "prompt.background":
      // The gateway starts the side agent before it answers, so a fast one can finish first.
      let isBtw = call["method"].stringValue == "prompt.btw"
      let (task, early): (String, String?) = locked {
        sideCount += 1
        return ("\(isBtw ? "btw" : "bg")_fixture\(sideCount)", sideAnswerFirst)
      }
      if let early {
        var payload: [String: JSONValue] = ["task_id": .string(task), "text": .string(early)]
        if isBtw { payload["question"] = params["text"] }
        emit(isBtw ? "btw.complete" : "background.complete", session: session, payload: .object(payload))
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { answer(.result(["task_id": .string(task)])) }
      } else {
        answer(.result(["task_id": .string(task)]))
      }
    case "session.active_list":
      answer(.result(["sessions": []]))
    default:
      answer(.result([:]))
    }
  }

  /// `session.mutate`: the rewind as the gateway runs it (fenced by revision and generation, an
  /// exact retry answered with its receipt, the target and everything after it taken off); any
  /// other operation is accepted.
  private func answerMutate(
    _ params: JSONValue, session: String, on connection: Connection, answer: @escaping @Sendable (Answer) -> Void
  ) {
    let requestID = params["request_id"].stringValue
    let operation = params["operation"].stringValue
    let target = params["payload"]["target_message_id"].int
    let (result, drop): (Answer, Bool) = locked {
      mutations.append(Mutation(session: session, requestID: requestID, operation: operation, target: target))
      if let receipt = receipts[requestID] { return (.result(receipt), false) }
      guard operation == "rewind", let target else { return (.result(["session_id": .string(session)]), false) }
      if movesOnBeforeNextMutate {
        movesOnBeforeNextMutate = false
        append("user", "Sent meanwhile", to: session)
        append("assistant", "Answered meanwhile", to: session)
        generations[session, default: 1] += 1
      }
      let revision = revisions[session] ?? 1
      let generation = generations[session] ?? 1
      guard params["expected_revision"].int == revision, params["expected_generation"].int == generation else {
        let reason = params["expected_revision"].int == revision ? "stale_generation" : "revision_conflict"
        return (.refusal(code: 4009, message: reason, data: [
          "reason": .string(reason), "revision": .number(Double(revision)), "execution_generation": .number(Double(generation)),
        ]), false)
      }
      var rows = transcripts[session] ?? []
      guard let index = rows.firstIndex(where: { $0["row_id"].int == target && $0["role"] == "user" }) else {
        return (.refusal(code: 4000, message: "target user message is no longer in session history", data: [
          "reason": "invalid_params",
        ]), false)
      }
      let taken = rows[index]
      let count = rows.count - index
      rows.removeSubrange(index...)
      transcripts[session] = rows
      revisions[session] = revision + 1
      let receipt: JSONValue = [
        "session_id": .string(session), "rewound_count": .number(Double(count)), "revision": .number(Double(revision + 1)),
        "target_message": ["id": taken["row_id"], "content": taken["content"], "timestamp": taken["timestamp"]],
        "new_head_id": rows.last?["row_id"] ?? .null,
      ]
      receipts[requestID] = receipt
      defer { dropsNextMutateAnswer = false }
      return (.result(receipt), dropsNextMutateAnswer)
    }
    if drop {
      // Applied, but the answer is lost with the socket.
      connection.connection.cancel()
    } else {
      let hold = locked {
        defer { holdsNextMutateAnswer = false }
        if holdsNextMutateAnswer { held.append { [queue] in queue.async { answer(result) } } }
        return holdsNextMutateAnswer
      }
      if !hold { answer(result) }
    }
  }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if done { return false }
    done = true
    return true
  }
}

/// One TCP connection: a plain HTTP request, or a WebSocket after `upgrade`. Runs on the fixture's queue.
private final class Connection: @unchecked Sendable {
  struct Request {
    let path: String
    let query: [String: String]
    let headers: [String: String]
  }

  let connection: NWConnection
  var onRequest: ((Request) -> Void)?
  var onMessage: ((String) -> Void)?
  var onClose: (() -> Void)?
  private(set) var isSocket = false
  private var buffer = Data()
  private var fragments = Data()

  init(connection: NWConnection) {
    self.connection = connection
  }

  func start(on queue: DispatchQueue) {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.onClose?()
      default: break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data { self.buffer.append(data) }
      if self.isSocket { self.readFrames() } else { self.readRequest() }
      if isComplete || error != nil {
        self.connection.cancel()
        return
      }
      self.receive()
    }
  }

  private func readRequest() {
    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    guard buffer.count >= end.upperBound + length else { return }
    buffer.removeSubrange(..<(end.upperBound + length))
    let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
    let path = String(target.prefix { $0 != "?" })
    let items = URLComponents(string: target)?.queryItems ?? []
    let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    onRequest?(Request(path: path.removingPercentEncoding ?? path, query: query, headers: headers))
  }

  func respond(_ body: JSONValue, status: Int = 200) {
    let data = body.data()
    let reason = status == 200 ? "OK" : "Error"
    let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { [weak self] _ in
      self?.connection.cancel()
    })
  }

  func upgrade(key: String) {
    let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: hermes-gateway-v1\r\n\r\n"
    isSocket = true
    connection.send(content: Data(head.utf8), completion: .idempotent)
    if !buffer.isEmpty { readFrames() }
  }

  func send(_ frame: JSONValue) {
    write(opcode: 0x1, payload: frame.data())
  }

  private func write(opcode: UInt8, payload: Data) {
    var frame = Data([0x80 | opcode])
    if payload.count < 126 {
      frame.append(UInt8(payload.count))
    } else if payload.count <= 0xFFFF {
      frame.append(126)
      frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
    } else {
      frame.append(127)
      frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) })
    }
    frame.append(payload)
    connection.send(content: frame, completion: .idempotent)
  }

  /// Client frames are masked (RFC 6455 5.3). Text, continuation, ping and close are handled.
  private func readFrames() {
    while true {
      let bytes = [UInt8](buffer.prefix(14))
      guard bytes.count >= 2 else { return }
      let fin = bytes[0] & 0x80 != 0
      let opcode = bytes[0] & 0x0F
      let masked = bytes[1] & 0x80 != 0
      var length = Int(bytes[1] & 0x7F)
      var offset = 2
      if length == 126 {
        guard bytes.count >= 4 else { return }
        length = Int(bytes[2]) << 8 | Int(bytes[3])
        offset = 4
      } else if length == 127 {
        guard bytes.count >= 10 else { return }
        length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
        offset = 10
      }
      let maskLength = masked ? 4 : 0
      guard buffer.count >= offset + maskLength + length else { return }
      let start = buffer.startIndex
      let mask = [UInt8](buffer[(start + offset)..<(start + offset + maskLength)])
      var payload = [UInt8](buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
      if masked { for index in payload.indices { payload[index] ^= mask[index % 4] } }
      buffer.removeSubrange(start..<(start + offset + maskLength + length))
      switch opcode {
      case 0x0, 0x1, 0x2:
        fragments.append(contentsOf: payload)
        if fin {
          let text = String(decoding: fragments, as: UTF8.self)
          fragments = Data()
          onMessage?(text)
        }
      case 0x8:
        write(opcode: 0x8, payload: Data())
        connection.cancel()
        return
      case 0x9:
        write(opcode: 0xA, payload: Data(payload))
      default:
        break
      }
    }
  }
}
