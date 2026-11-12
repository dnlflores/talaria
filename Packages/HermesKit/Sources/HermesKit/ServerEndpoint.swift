import Foundation

/// Where Hermes lives: the public address of the gateway's own listener on the Mac (Hermes'
/// Webapp listener, published with Tailscale Funnel, behind Hermes' sign-in), or its loopback
/// address when the app runs in the simulator on the same machine.
public struct ServerEndpoint: Sendable, Hashable, Codable {
  /// Scheme, host, optional port and optional path prefix, without a trailing slash.
  public let baseURL: URL

  /// Accepts what a person types: `host`, `host:8443`, `https://host:8443/`, `http://127.0.0.1:4300`.
  /// A bare host gets `https`, except loopback, which gets `http`.
  public init?(userInput: String) {
    var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") {
      let host = text.split(separator: "/").first.map(String.init) ?? text
      let name = host.split(separator: ":").first.map(String.init) ?? host
      let loopback = name == "localhost" || name == "127.0.0.1" || host.hasPrefix("[::1]")
      text = (loopback ? "http://" : "https://") + text
    }
    while text.hasSuffix("/") { text.removeLast() }
    guard let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      let url = components.url
    else { return nil }
    baseURL = url
  }

  public var isSecure: Bool { baseURL.scheme?.lowercased() == "https" }

  /// `scheme://host[:port]`, the value the gate compares against the Host header on writes and WebSocket upgrades.
  public var origin: String {
    let scheme = baseURL.scheme?.lowercased() ?? "https"
    let host = baseURL.host(percentEncoded: true) ?? ""
    let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    if let port = baseURL.port { return "\(scheme)://\(bracketed):\(port)" }
    return "\(scheme)://\(bracketed)"
  }

  /// Host and port as a person would recognize them.
  public var displayName: String {
    let host = baseURL.host(percentEncoded: false) ?? baseURL.absoluteString
    if let port = baseURL.port { return "\(host):\(port)" }
    return host
  }

  public func url(path: String, query: [(String, String)] = []) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    let prefix = components.percentEncodedPath
    let encoded = path.split(separator: "/", omittingEmptySubsequences: true)
      .map { $0.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? String($0) }
      .joined(separator: "/")
    components.percentEncodedPath = prefix + "/" + encoded
    if !query.isEmpty {
      components.percentEncodedQuery = query
        .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
        .joined(separator: "&")
    }
    return components.url ?? baseURL
  }

  /// The gateway's chat socket: the process the desktop app runs its chats in, so chats driven
  /// through it are the same live chats the desktop app shows. A one-use ticket from
  /// `/api/auth/ws-ticket` admits it.
  public var webSocketURL: URL {
    var components = URLComponents(url: url(path: "/api/ws"), resolvingAgainstBaseURL: false) ?? URLComponents()
    components.scheme = isSecure ? "wss" : "ws"
    return components.url ?? baseURL
  }

  private static let pathSegmentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// Percent-encodes everything outside the RFC 3986 unreserved set (so `+`, `&` and `=` survive form decoding).
  public static func formEncode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? text
  }
}
