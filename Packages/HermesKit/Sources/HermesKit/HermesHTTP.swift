import Foundation

/// What the gate says before any session exists.
public enum GateStatus: Sendable, Equatable {
  /// Reachable and either ungated (loopback) or already signed in.
  case open(GateHealth)
  case loginRequired
  case noPasswordConfigured
}

public struct GateHealth: Sendable, Equatable {
  public var backendState: String
  public var backendError: String
  public var home: String
  public var isPublicListener: Bool

  public init(json: JSONValue) {
    backendState = json["backend"]["state"].stringValue
    backendError = json["backend"]["error"].stringValue
    home = json["home"].stringValue
    isPublicListener = json["public"].truthy
  }

  public var backendIsRunning: Bool { backendState == "running" }
}

/// REST access to the gate. Cookies are handled by hand (one `hd_session` value from the
/// `SessionCookieStore`) so the same credential drives REST and the WebSocket, and nothing
/// leaks into shared cookie storage.
public final class HermesHTTP: Sendable {
  public static let cookieName = "hd_session"

  public let endpoint: ServerEndpoint
  private let cookies: any SessionCookieStore
  private let session: URLSession

  public init(endpoint: ServerEndpoint, cookies: any SessionCookieStore) {
    self.endpoint = endpoint
    self.cookies = cookies
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
  }

  // MARK: Requests

  func request(_ method: String, path: String, query: [(String, String)] = [], timeout: TimeInterval = 30) -> URLRequest {
    var request = URLRequest(url: endpoint.url(path: path, query: query), timeoutInterval: timeout)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
    if let cookie = cookies.cookie(for: endpoint) {
      request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
    }
    return request
  }

  /// Sends a request and decodes a JSON answer. Non-JSON bodies come back as `.string`.
  @discardableResult
  public func json(
    _ method: String = "GET", _ path: String, query: [(String, String)] = [], body: JSONValue? = nil,
    timeout: TimeInterval = 30
  ) async throws -> JSONValue {
    var request = request(method, path: path, query: query, timeout: timeout)
    if let body {
      request.httpBody = body.data()
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await perform(request)
    let parsed = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
    let status = response.statusCode
    if status == 401, response.value(forHTTPHeaderField: "X-Hermesdash-Login") != nil {
      throw HermesError.loginRequired
    }
    guard (200..<300).contains(status) else {
      throw HermesError.http(status: status, message: Self.message(from: parsed, status: status))
    }
    return parsed
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse("not an HTTP response") }
      return (data, http)
    } catch {
      throw HermesError.wrap(error)
    }
  }

  /// Downloads a body to a file of its own and returns where it landed, named the way the server
  /// named it (`Content-Disposition`), so the share sheet and Quick Look see a real file name.
  public func download(
    _ path: String, query: [(String, String)] = [], suggestedName: String, timeout: TimeInterval = 300
  ) async throws -> URL {
    let request = request("GET", path: path, query: query, timeout: timeout)
    let (temporary, response): (URL, URLResponse)
    do {
      (temporary, response) = try await session.download(for: request)
    } catch {
      throw HermesError.wrap(error)
    }
    guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse("not an HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
      let data = (try? Data(contentsOf: temporary)) ?? Data()
      try? FileManager.default.removeItem(at: temporary)
      if http.statusCode == 401, http.value(forHTTPHeaderField: "X-Hermesdash-Login") != nil { throw HermesError.loginRequired }
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

  // MARK: Gate

  public func probe() async throws -> GateStatus {
    let (data, response) = try await perform(request("GET", path: "/hd/health", timeout: 15))
    switch response.statusCode {
    case 200:
      guard let json = try? JSONValue.parse(data), json["ok"].truthy else {
        throw HermesError.notAHermesGate("no health answer")
      }
      return .open(GateHealth(json: json))
    case 401 where response.value(forHTTPHeaderField: "X-Hermesdash-Login") != nil:
      return .loginRequired
    case 503:
      return .noPasswordConfigured
    default:
      throw HermesError.notAHermesGate("HTTP \(response.statusCode)")
    }
  }

  /// Trades the password for a session cookie and stores it. The password is not kept.
  public func login(password: String) async throws {
    var request = request("POST", path: "/login", timeout: 20)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.httpBody = Data("password=\(ServerEndpoint.formEncode(password))".utf8)
    let (data, response) = try await perform(request)
    switch response.statusCode {
    case 200, 302, 303:
      guard let value = Self.sessionCookie(in: response, for: endpoint.baseURL) else {
        throw HermesError.invalidResponse("the Mac accepted the password but sent no session")
      }
      cookies.setCookie(value, for: endpoint)
    case 401:
      let page = String(decoding: data, as: UTF8.self).lowercased()
      throw page.contains("too many attempts") ? HermesError.tooManyAttempts : HermesError.wrongPassword
    case 503:
      throw HermesError.noPasswordConfigured
    default:
      let parsed = (try? JSONValue.parse(data)) ?? .null
      throw HermesError.http(status: response.statusCode, message: Self.message(from: parsed, status: response.statusCode))
    }
  }

  public func logout() async {
    _ = try? await json("POST", "/hd/logout")
    cookies.setCookie(nil, for: endpoint)
  }

  public var hasSession: Bool { cookies.cookie(for: endpoint) != nil }

  static func sessionCookie(in response: HTTPURLResponse, for url: URL) -> String? {
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let value = value as? String { headers[key] = value }
    }
    return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
      .first { $0.name == cookieName && !$0.value.isEmpty }?.value
  }
}

/// The login answer is a redirect that carries the cookie; following it would lose the header we need.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
