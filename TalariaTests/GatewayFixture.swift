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

  /// How the fixture answers a call: a result, or a JSON-RPC error.
  enum Answer: Sendable {
    case result(JSONValue)
    case error(code: Int, message: String)
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
      // Sign-in is offered but not done: the app stays off its inbox and the test drives the chat.
      body = ["auth_required": true, "auth_providers": ["nous"], "gateway_running": true, "version": "fixture"]
    case let path where path.hasPrefix("/api/sessions/") && path.hasSuffix("/messages"):
      let session = String(path.dropFirst("/api/sessions/".count).dropLast("/messages".count))
      let rows: [JSONValue] = submitted.filter { $0.session == session }.enumerated().map { index, prompt in
        ["id": .number(Double(index + 1)), "role": "user", "content": .string(prompt.text)]
      }
      body = ["messages": .array(rows), "total": .number(Double(rows.count)), "has_more": false]
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
      }
    }
    switch call["method"].stringValue {
    case "session.create", "session.resume":
      let isRunning = locked { running.contains(session) }
      answer(.result([
        "session_id": .string(session), "stored_session_id": .string(session), "subscription_id": "fixture",
        "running": .bool(isRunning), "messages": [], "execution_generation": 1, "session_revision": 1,
        "profile": "preview",
      ]))
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
          locked { prompts.append(prompt) }
          answer(.result(["admission_id": .string(UUID().uuidString)]))
        }
      }
      if hold { locked { held.append { [queue] in queue.async(execute: finish) } } } else { finish() }
    case "file.attach":
      answer(.result(["attached": true, "ref_text": .string("@file:/fixture/\(params["name"].stringValue)")]))
    case "session.active_list":
      answer(.result(["sessions": []]))
    default:
      answer(.result([:]))
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
    onRequest?(Request(path: path.removingPercentEncoding ?? path, headers: headers))
  }

  func respond(_ body: JSONValue) {
    let data = body.data()
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
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
