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
