import Foundation

/// What Hermes on the Mac says before any session exists.
public enum GateStatus: Sendable, Equatable {
  /// Reachable, and signed in (or open without sign-in, on this Mac's loopback).
  case open(GateHealth)
  /// Reachable; sign in first.
  case loginRequired
  /// Reachable, but it offers no sign-in this app can use (none configured on the Mac).
  case noSignInConfigured
}

public struct GateHealth: Sendable, Equatable {
  public var version: String
  /// `hermes_home` when the status names it; Hermes' own listener leaves it out (see `HermesClient.macHome`).
  public var home: String
  public var gatewayRunning: Bool

  public init(json: JSONValue) {
    version = json["version"].stringValue
    home = json["hermes_home"].stringValue
    gatewayRunning = json["gateway_running"].truthy
  }
}

/// REST access to Hermes' own listener on the Mac: the gateway's Webapp listener, which the
/// desktop app's runtime serves. A signed-in request carries the sign-in's bearer token; a token
/// that ran out is renewed once (`/auth/native/refresh`) and the request retried.
public final class HermesHTTP: Sendable {
  public let endpoint: ServerEndpoint
  private let signIns: any SignInStore
  private let session: URLSession
  private let renewal = Renewal()

  public init(endpoint: ServerEndpoint, signIns: any SignInStore, protocolClasses: [AnyClass]? = nil) {
    self.endpoint = endpoint
    self.signIns = signIns
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    if let protocolClasses { configuration.protocolClasses = protocolClasses }
    session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
  }

  public var hasSession: Bool { signIns.signIn(for: endpoint) != nil }

  // MARK: Requests

  func request(_ method: String, path: String, query: [(String, String)] = [], timeout: TimeInterval = 30) -> URLRequest {
    var request = URLRequest(url: endpoint.url(path: path, query: query), timeoutInterval: timeout)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let signIn = signIns.signIn(for: endpoint) {
      request.setValue("Bearer \(signIn.accessToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  /// Sends a request and decodes a JSON answer. Non-JSON bodies come back as `.string`.
  @discardableResult
  public func json(
    _ method: String = "GET", _ path: String, query: [(String, String)] = [], body: JSONValue? = nil,
    timeout: TimeInterval = 30
  ) async throws -> JSONValue {
    let (data, response) = try await authorized {
      var request = self.request(method, path: path, query: query, timeout: timeout)
      if let body {
        request.httpBody = body.data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      return try await self.perform(request)
    }
    let parsed = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
    let status = response.statusCode
    guard (200..<300).contains(status) else {
      throw HermesError.http(status: status, message: Self.message(from: parsed, status: status))
    }
    return parsed
  }

  /// Runs a signed request; on 401 renews the sign-in once and runs it again. Still 401: signed out.
  private func authorized<T: Sendable>(
    _ send: @Sendable () async throws -> (T, HTTPURLResponse)
  ) async throws -> (T, HTTPURLResponse) {
    if let signIn = signIns.signIn(for: endpoint), signIn.expiresSoon() {
      _ = try? await renew(signIn)
    }
    let first = try await send()
    guard first.1.statusCode == 401 else { return first }
    guard let signIn = signIns.signIn(for: endpoint) else { throw HermesError.loginRequired }
    try await renew(signIn)
    let second = try await send()
    if second.1.statusCode == 401 {
      signIns.setSignIn(nil, for: endpoint)
      throw HermesError.loginRequired
    }
    return second
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse("not an HTTP response") }
      return (data, http)
    } catch let error as HermesError {
      throw error
    } catch {
      throw HermesError.wrap(error)
    }
  }

  /// Downloads a body to a file of its own and returns where it landed, named the way the server
  /// named it (`Content-Disposition`), so the share sheet and Quick Look see a real file name.
  public func download(
    _ path: String, query: [(String, String)] = [], suggestedName: String, timeout: TimeInterval = 300
  ) async throws -> URL {
    let (temporary, http): (URL, HTTPURLResponse) = try await authorized {
      let request = self.request("GET", path: path, query: query, timeout: timeout)
      let (temporary, response): (URL, URLResponse)
      do {
        (temporary, response) = try await self.session.download(for: request)
      } catch {
        throw HermesError.wrap(error)
      }
      guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse("not an HTTP response") }
      if http.statusCode == 401 { try? FileManager.default.removeItem(at: temporary) }
      return (temporary, http)
    }
    guard (200..<300).contains(http.statusCode) else {
      let data = (try? Data(contentsOf: temporary)) ?? Data()
      try? FileManager.default.removeItem(at: temporary)
      let parsed = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
      throw HermesError.http(status: http.statusCode, message: Self.message(from: parsed, status: http.statusCode))
    }
    let name = Self.filename(from: http.value(forHTTPHeaderField: "Content-Disposition")) ?? suggestedName
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("downloads", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(Self.safeFilename(name), isDirectory: false)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  static func filename(from disposition: String?) -> String? {
    guard let disposition else { return nil }
    if let match = disposition.firstMatch(of: /(?i)filename\*=UTF-8''([^;]+)/),
      let decoded = String(match.1).removingPercentEncoding, !decoded.isEmpty
    {
      return decoded
    }
    if let match = disposition.firstMatch(of: /(?i)filename="([^"]+)"/) { return String(match.1) }
    if let match = disposition.firstMatch(of: /(?i)filename=([^;]+)/) {
      return String(match.1).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  static func safeFilename(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned.hasPrefix(".") && cleaned.count < 2 ? "download" : cleaned
  }

  static func message(from body: JSONValue, status: Int) -> String {
    for key in ["detail", "error", "message"] {
      let value = body[key]
      if let text = value.string, !text.isEmpty { return text }
      if value.object != nil || value.array != nil { return value.text() }
    }
    if let text = body.string {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, !trimmed.hasPrefix("<") { return String(trimmed.prefix(300)) }
    }
    return "HTTP \(status)"
  }

  // MARK: Sign-in

  /// Whether the address is Hermes, whether it wants a sign-in, and whether the one held works.
  public func probe() async throws -> GateStatus {
    let (data, response) = try await perform(request("GET", path: "/api/status", timeout: 15))
    guard response.statusCode == 200, let status = try? JSONValue.parse(data), status["version"].string != nil else {
      throw HermesError.notAHermesGate("HTTP \(response.statusCode)")
    }
    let health = GateHealth(json: status)
    guard status["auth_required"].truthy else { return .open(health) }
    let providers = status["auth_providers"].array ?? []
    if providers.isEmpty { return .noSignInConfigured }
    guard hasSession else { return .loginRequired }
    do {
      _ = try await json("GET", "/api/auth/me", timeout: 15)
      return .open(health)
    } catch HermesError.loginRequired {
      return .loginRequired
    }
  }

  /// Where the sign-in sheet starts: Hermes' native-app authorization (RFC 8252), which sends the
  /// browser through the Mac's sign-in provider and back to `redirectURI` with a one-time code.
  public func authorizeURL(_ authorization: NativeAuthorization, redirectURI: String) -> URL {
    endpoint.url(path: "/auth/native/authorize", query: [
      ("code_challenge", authorization.challenge), ("code_challenge_method", "S256"),
      ("redirect_uri", redirectURI), ("state", authorization.state),
    ])
  }

  /// Trades the one-time code for tokens and keeps them.
  public func completeSignIn(code: String, verifier: String) async throws {
    var request = request("POST", path: "/auth/native/token", timeout: 30)
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = (["code": .string(code), "code_verifier": .string(verifier)] as JSONValue).data()
    let (data, response) = try await perform(request)
    let parsed = (try? JSONValue.parse(data)) ?? .null
    guard response.statusCode == 200 else {
      throw HermesError.signInFailed(Self.message(from: parsed, status: response.statusCode))
    }
    signIns.setSignIn(try SignIn(json: parsed), for: endpoint)
  }

  /// Renews the access token with the refresh token. Concurrent callers share one renewal.
  @discardableResult
  func renew(_ stale: SignIn) async throws -> SignIn {
    try await renewal.run(stale: stale) { [self] in
      // Another caller renewed it meanwhile.
      if let current = signIns.signIn(for: endpoint), current != stale { return current }
      guard !stale.refreshToken.isEmpty else {
        signIns.setSignIn(nil, for: endpoint)
        throw HermesError.loginRequired
      }
      var request = request("POST", path: "/auth/native/refresh", timeout: 30)
      request.setValue(nil, forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = (["refresh_token": .string(stale.refreshToken), "provider": .string(stale.provider)] as JSONValue).data()
      let (data, response) = try await perform(request)
      switch response.statusCode {
      case 200:
        var fresh = try SignIn(json: (try? JSONValue.parse(data)) ?? .null)
        if fresh.refreshToken.isEmpty { fresh.refreshToken = stale.refreshToken }
        if fresh.provider.isEmpty { fresh.provider = stale.provider }
        signIns.setSignIn(fresh, for: endpoint)
        return fresh
      case 400, 401, 403:
        signIns.setSignIn(nil, for: endpoint)
        throw HermesError.loginRequired
      default:
        let parsed = (try? JSONValue.parse(data)) ?? .null
        throw HermesError.http(status: response.statusCode, message: Self.message(from: parsed, status: response.statusCode))
      }
    }
  }

  /// A one-use ticket that admits one WebSocket (`/api/ws`) as this sign-in. Nil when the
  /// listener needs no sign-in (this Mac's loopback without a public address).
  public func socketTicket() async throws -> String? {
    guard hasSession else { return nil }
    let json = try await json("POST", "/api/auth/ws-ticket", timeout: 20)
    guard let ticket = json["ticket"].string, !ticket.isEmpty else {
      throw HermesError.invalidResponse("the Mac gave no socket ticket")
    }
    return ticket
  }

  /// Signs out on this device: forgets the tokens. Hermes has no sign-out route for a native
  /// app's bearer tokens (`/auth/logout` revokes a browser's cookie session only).
  public func logout() async {
    signIns.setSignIn(nil, for: endpoint)
  }
}

/// Coalesces token renewals: one refresh call however many requests found the token stale.
private actor Renewal {
  private var running: Task<SignIn, any Error>?

  func run(stale: SignIn, _ body: @escaping @Sendable () async throws -> SignIn) async throws -> SignIn {
    if let running { return try await running.value }
    let task = Task { try await body() }
    running = task
    defer { running = nil }
    return try await task.value
  }
}

/// Redirects are answers here (the sign-in endpoints never redirect a native call); following one
/// would drop the Authorization header.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
