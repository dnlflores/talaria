import CryptoKit
import Foundation
import Network
import Security

/// One native sign-in attempt's secrets: the PKCE verifier and its challenge (RFC 7636, S256) and
/// the `state` that ties the browser's return to this attempt.
public struct NativeAuthorization: Sendable {
  public let verifier: String
  public let challenge: String
  public let state: String

  public init() {
    verifier = Self.randomToken(bytes: 32)
    challenge = Self.challenge(for: verifier)
    state = Self.randomToken(bytes: 16)
  }

  static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func randomToken(bytes count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
      var generator = SystemRandomNumberGenerator()
      bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
    return base64URL(Data(bytes))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// Where the browser comes back to at the end of a native sign-in: an HTTP listener on 127.0.0.1
/// (RFC 8252 §7.3; Hermes takes only a loopback redirect for native apps). The browser's request
/// to `/callback` carries the one-time code; the listener answers it with a redirect to
/// `returnURL` (the app's own scheme, which closes the sign-in sheet) and stops.
public final class LoopbackRedirect: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "talaria.loopback-redirect")
  private let returnURL: String
  private let lock = NSLock()
  private var portWaiter: CheckedContinuation<UInt16, any Error>?
  private var callbackWaiter: CheckedContinuation<URLComponents, any Error>?
  private var outcome: Result<URLComponents, any Error>?

  private static let maxRequestBytes = 16 * 1024

  public init(returnURL: String) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    self.returnURL = returnURL
  }

  /// Starts listening and returns the redirect URI to give Hermes.
  public func start() async throws -> String {
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      lock.withLock { portWaiter = continuation }
      listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
    }
    return "http://127.0.0.1:\(port)/callback"
  }

  /// Waits for the browser to come back, checks it answers this attempt, and returns the code.
  public func code(expectedState: String) async throws -> String {
    let components: URLComponents = try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if let outcome { continuation.resume(with: outcome) } else { callbackWaiter = continuation }
      }
    }
    return try Self.code(from: components, expectedState: expectedState)
  }

  /// The person closed the sign-in sheet, or it failed: stop waiting.
  public func cancel(_ error: any Error = HermesError.signInCancelled) {
    settle(.failure(error))
    listener.cancel()
  }

  static func code(from components: URLComponents, expectedState: String) throws -> String {
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    if let error = value("error"), !error.isEmpty {
      throw HermesError.signInFailed(value("error_description") ?? error)
    }
    guard value("state") == expectedState else {
      throw HermesError.signInFailed("the sign-in came back for another request")
    }
    guard let code = value("code"), !code.isEmpty else {
      throw HermesError.signInFailed("the sign-in came back without a code")
    }
    return code
  }

  // MARK: Listener

  private func listenerChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      let port = listener.port?.rawValue ?? 0
      lock.withLock {
        portWaiter?.resume(returning: port)
        portWaiter = nil
      }
    case .failed(let error):
      lock.withLock {
        portWaiter?.resume(throwing: error)
        portWaiter = nil
      }
      settle(.failure(HermesError.signInFailed(error.localizedDescription)))
    case .cancelled:
      lock.withLock {
        portWaiter?.resume(throwing: HermesError.signInCancelled)
        portWaiter = nil
      }
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      guard let head = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        if isComplete || error != nil || buffer.count > Self.maxRequestBytes {
          connection.cancel()
        } else {
          self.read(connection, buffer: buffer)
        }
        return
      }
      let requestLine = String(decoding: buffer[..<head.lowerBound], as: UTF8.self)
        .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
      self.answer(connection, requestLine: requestLine)
    }
  }

  private func answer(_ connection: NWConnection, requestLine: String) {
    let parts = requestLine.split(separator: " ")
    let target = parts.count >= 2 ? String(parts[1]) : ""
    guard parts.first == "GET", let components = URLComponents(string: "http://127.0.0.1\(target)"),
      components.path == "/callback"
    else {
      // A favicon or a stray request: not the sign-in coming back.
      send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      return
    }
    let response = "HTTP/1.1 302 Found\r\nLocation: \(returnURL)\r\nCache-Control: no-store\r\n"
      + "Content-Length: 0\r\nConnection: close\r\n\r\n"
    send(connection, response) { [weak self] in
      self?.settle(.success(components))
      self?.listener.cancel()
    }
  }

  private func send(_ connection: NWConnection, _ text: String, then done: (@Sendable () -> Void)? = nil) {
    connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
      connection.cancel()
      done?()
    })
  }

  private func settle(_ result: Result<URLComponents, any Error>) {
    let waiter: CheckedContinuation<URLComponents, any Error>? = lock.withLock {
      guard outcome == nil else { return nil }
      outcome = result
      defer { callbackWaiter = nil }
      return callbackWaiter
    }
    waiter?.resume(with: result)
  }
}
