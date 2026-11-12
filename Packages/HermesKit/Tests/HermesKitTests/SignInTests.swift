import Foundation
import Testing

@testable import HermesKit

/// A stand-in for Hermes' listener: answers each request with a handler the test sets.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Reply: Sendable {
    var status: Int
    var body: JSONValue
  }

  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
  nonisolated(unsafe) static var seen: [URLRequest] = []
  static let lock = NSLock()

  static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
    lock.withLock {
      self.handler = handler
      seen = []
    }
  }

  static var requests: [URLRequest] { lock.withLock { seen } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var request = request
    if request.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      stream.close()
      request.httpBody = data
    }
    let handler = Self.lock.withLock {
      Self.seen.append(request)
      return Self.handler
    }
    let reply = handler?(request) ?? Reply(status: 500, body: ["detail": "no handler"])
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [
      "Content-Type": "application/json"
    ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body.data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Signing in with Hermes' native-app flow and staying signed in. Serialized: they share the stub.
@Suite(.serialized) struct SignInTests {
  let endpoint = ServerEndpoint(userInput: "my-mac.example.ts.net:10000")!

  private func http(_ store: any SignInStore) -> HermesHTTP {
    HermesHTTP(endpoint: endpoint, signIns: store, protocolClasses: [StubProtocol.self])
  }

  private static func bearer(_ request: URLRequest) -> String? {
    request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
  }

  @Test func pkceChallengeIsTheS256OfTheVerifier() {
    // RFC 7636 appendix B.
    #expect(NativeAuthorization.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let one = NativeAuthorization()
    let two = NativeAuthorization()
    #expect(one.verifier != two.verifier && one.state != two.state)
    #expect(one.verifier.count >= 43 && !one.verifier.contains("="))
  }

  @Test func theAuthorizeURLCarriesTheChallengeAndLoopbackRedirect() throws {
    let auth = NativeAuthorization()
    let url = http(InMemorySignInStore()).authorizeURL(auth, redirectURI: "http://127.0.0.1:53111/callback")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "my-mac.example.ts.net" && components.port == 10000)
    #expect(components.path == "/auth/native/authorize")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["code_challenge"] == auth.challenge)
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["redirect_uri"] == "http://127.0.0.1:53111/callback")
    #expect(query["state"] == auth.state)
  }

  @Test func theCodeIsTradedForTokensThatSignEveryRequest() async throws {
    StubProtocol.reset { request in
      switch request.url!.path {
      case "/auth/native/token":
        let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
        guard body["code"] == "c0de", body["code_verifier"] == "v3rifier" else { return .init(status: 400, body: ["detail": "bad"]) }
        return .init(status: 200, body: ["access_token": "A1", "refresh_token": "R1", "expires_at": 4_000_000_000, "provider": "nous"])
      case "/api/profiles/sessions/sidebar":
        return Self.bearer(request) == "A1" ? .init(status: 200, body: ["recents": [:]]) : .init(status: 401, body: [:])
      default:
        return .init(status: 404, body: [:])
      }
    }
    let store = InMemorySignInStore()
    let http = http(store)
    try await http.completeSignIn(code: "c0de", verifier: "v3rifier")
    #expect(store.signIn(for: endpoint) == SignIn(accessToken: "A1", refreshToken: "R1", expiresAt: 4_000_000_000, provider: "nous"))
    _ = try await http.json("GET", "/api/profiles/sessions/sidebar")
    // The token exchange itself carried no bearer.
    #expect(Self.bearer(StubProtocol.requests[0]) == nil)

    await #expect(throws: HermesError.signInFailed("bad")) { try await http.completeSignIn(code: "nope", verifier: "v3rifier") }
  }

  @Test func aTokenThatRanOutIsRenewedOnceForManyRequests() async throws {
    StubProtocol.reset { request in
      switch request.url!.path {
      case "/auth/native/refresh":
        let body = (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
        guard body["refresh_token"] == "R1", body["provider"] == "nous" else { return .init(status: 401, body: [:]) }
        return .init(status: 200, body: ["access_token": "A2", "refresh_token": "R2", "provider": "nous"])
      default:
        return Self.bearer(request) == "A2" ? .init(status: 200, body: ["ok": true]) : .init(status: 401, body: [:])
      }
    }
    let store = InMemorySignInStore(SignIn(accessToken: "A1", refreshToken: "R1", expiresAt: nil, provider: "nous"), for: endpoint)
    let http = http(store)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 { group.addTask { _ = try await http.json("GET", "/api/sessions") } }
      try await group.waitForAll()
    }
    #expect(store.signIn(for: endpoint)?.accessToken == "A2")
    #expect(store.signIn(for: endpoint)?.refreshToken == "R2")
    #expect(StubProtocol.requests.filter { $0.url!.path == "/auth/native/refresh" }.count == 1)
  }

  @Test func aRefusedRenewalSignsOut() async throws {
    StubProtocol.reset { request in
      request.url!.path == "/auth/native/refresh"
        ? .init(status: 401, body: ["error": "session_expired"]) : .init(status: 401, body: ["detail": "Unauthorized"])
    }
    let store = InMemorySignInStore(SignIn(accessToken: "A1", refreshToken: "R1", expiresAt: nil, provider: "nous"), for: endpoint)
    await #expect(throws: HermesError.loginRequired) { try await http(store).json("GET", "/api/sessions") }
    #expect(store.signIn(for: endpoint) == nil)
  }

  @Test func probeTellsOpenFromSignInNeeded() async throws {
    let status: JSONValue = ["version": "0.23.1", "auth_required": true, "auth_providers": ["nous"], "hermes_home": "/h", "gateway_running": true]
    StubProtocol.reset { request in
      switch request.url!.path {
      case "/api/status": return .init(status: 200, body: status)
      case "/api/auth/me": return Self.bearer(request) == "A1" ? .init(status: 200, body: ["user_id": "u"]) : .init(status: 401, body: [:])
      default: return .init(status: 404, body: [:])
      }
    }
    #expect(try await http(InMemorySignInStore()).probe() == .loginRequired)
    let signed = InMemorySignInStore(SignIn(accessToken: "A1", refreshToken: "", expiresAt: nil, provider: "nous"), for: endpoint)
    guard case .open(let health) = try await http(signed).probe() else {
      Issue.record("expected open")
      return
    }
    #expect(health.home == "/h" && health.gatewayRunning)
  }

  @Test func theSocketIsAdmittedWithATicketSubprotocol() async throws {
    StubProtocol.reset { request in
      request.url!.path == "/api/auth/ws-ticket" && Self.bearer(request) == "A1"
        ? .init(status: 200, body: ["ticket": "T1", "ttl_seconds": 30]) : .init(status: 401, body: [:])
    }
    let store = InMemorySignInStore(SignIn(accessToken: "A1", refreshToken: "", expiresAt: nil, provider: "nous"), for: endpoint)
    let ticket = try await http(store).socketTicket()
    #expect(ticket == "T1")
    let upgrade = RPCConnection.upgradeRequest(endpoint: endpoint, ticket: ticket)
    #expect(upgrade.url?.absoluteString == "wss://my-mac.example.ts.net:10000/api/ws")
    #expect(upgrade.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "hermes-gateway-v1, hermes-gateway-ticket.T1")
    #expect(try await http(InMemorySignInStore()).socketTicket() == nil)
  }
}

/// The browser's return to the app at the end of sign-in.
@Suite struct LoopbackRedirectTests {
  private func get(_ url: String) async throws -> HTTPURLResponse {
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
      func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
      ) async -> URLRequest? { nil }
    }
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    let (_, response) = try await session.data(from: URL(string: url)!)
    return response as! HTTPURLResponse
  }

  @Test func theBrowsersReturnHandsOverTheCodeAndClosesTheSheet() async throws {
    let loopback = try LoopbackRedirect(returnURL: "talaria-auth://signed-in")
    let redirect = try await loopback.start()
    #expect(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/callback"))
    let stray = try await get(redirect.replacingOccurrences(of: "/callback", with: "/favicon.ico"))
    #expect(stray.statusCode == 404)
    async let code = loopback.code(expectedState: "s1")
    let back = try await get("\(redirect)?code=abc123&state=s1")
    #expect(back.statusCode == 302)
    #expect(back.value(forHTTPHeaderField: "Location") == "talaria-auth://signed-in")
    #expect(try await code == "abc123")
  }

  @Test func aReturnForAnotherAttemptOrAnErrorIsRefused() throws {
    func components(_ query: String) -> URLComponents { URLComponents(string: "http://127.0.0.1/callback?\(query)")! }
    #expect(throws: HermesError.signInFailed("the sign-in came back for another request")) {
      try LoopbackRedirect.code(from: components("code=x&state=other"), expectedState: "s1")
    }
    #expect(throws: HermesError.signInFailed("Access denied")) {
      try LoopbackRedirect.code(from: components("error=access_denied&error_description=Access%20denied&state=s1"), expectedState: "s1")
    }
  }

  @Test func closingTheSheetStopsTheWait() async throws {
    let loopback = try LoopbackRedirect(returnURL: "talaria-auth://signed-in")
    _ = try await loopback.start()
    loopback.cancel()
    await #expect(throws: HermesError.signInCancelled) { try await loopback.code(expectedState: "s1") }
  }
}
