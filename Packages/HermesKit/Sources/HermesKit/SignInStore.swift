import Foundation
import Security

/// What signing in to Hermes on the Mac leaves on the phone: the bearer token every request
/// carries and the refresh token that renews it. Hermes hands both out at the end of its native
/// app sign-in (`/auth/native/token`, RFC 8252) and rotates them at `/auth/native/refresh`.
public struct SignIn: Sendable, Codable, Equatable {
  public var accessToken: String
  public var refreshToken: String
  /// When the access token stops working, seconds since 1970; nil when the provider did not say.
  public var expiresAt: Double?
  /// The sign-in provider that issued the tokens (`nous`); refresh names it.
  public var provider: String

  public init(accessToken: String, refreshToken: String, expiresAt: Double?, provider: String) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.provider = provider
  }

  /// The token answer of `/auth/native/token` and `/auth/native/refresh`.
  init(json: JSONValue) throws {
    guard let access = json["access_token"].string, !access.isEmpty else {
      throw HermesError.invalidResponse("the sign-in gave no access token")
    }
    accessToken = access
    refreshToken = json["refresh_token"].stringValue
    expiresAt = json["expires_at"].double
    provider = json["provider"].stringValue
  }

  /// The access token runs out within a minute: renew it before using it.
  public func expiresSoon(now: Double = Date().timeIntervalSince1970) -> Bool {
    guard let expiresAt else { return false }
    return now >= expiresAt - 60
  }
}

/// Keeps the sign-in per Mac (endpoint origin).
public protocol SignInStore: Sendable {
  func signIn(for endpoint: ServerEndpoint) -> SignIn?
  func setSignIn(_ value: SignIn?, for endpoint: ServerEndpoint)
}

public final class InMemorySignInStore: SignInStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: SignIn] = [:]

  public init(_ initial: SignIn? = nil, for endpoint: ServerEndpoint? = nil) {
    if let initial, let endpoint { values[endpoint.origin] = initial }
  }

  public func signIn(for endpoint: ServerEndpoint) -> SignIn? {
    lock.withLock { values[endpoint.origin] }
  }

  public func setSignIn(_ value: SignIn?, for endpoint: ServerEndpoint) {
    lock.withLock { values[endpoint.origin] = value }
  }
}

/// Keychain-backed store: one generic-password item per endpoint origin, holding the tokens as JSON.
public struct KeychainSignInStore: SignInStore {
  private let service: String

  public init(service: String) {
    self.service = service
  }

  private func query(_ endpoint: ServerEndpoint) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: endpoint.origin,
    ]
  }

  public func signIn(for endpoint: ServerEndpoint) -> SignIn? {
    var request = query(endpoint)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return try? JSONDecoder().decode(SignIn.self, from: data)
  }

  public func setSignIn(_ value: SignIn?, for endpoint: ServerEndpoint) {
    SecItemDelete(query(endpoint) as CFDictionary)
    guard let value, let data = try? JSONEncoder().encode(value) else { return }
    var item = query(endpoint)
    item[kSecValueData as String] = data
    // Readable after the first unlock so a reconnect while the phone is locked still works.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }
}

/// A sign-in kept in a JSON file (`scripts/sign-in.py` writes one), for the live tests and the
/// simulator's UI tests. Renewals rotate the refresh token, so they are written back; signing out
/// leaves the file alone, so one test that signs out does not sign out the rest.
public final class FileSignInStore: SignInStore, @unchecked Sendable {
  private let url: URL
  private let lock = NSLock()

  public init(path: String) {
    url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  }

  public func signIn(for endpoint: ServerEndpoint) -> SignIn? {
    lock.withLock {
      guard let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data) else { return nil }
      return try? SignIn(json: json)
    }
  }

  public func setSignIn(_ value: SignIn?, for endpoint: ServerEndpoint) {
    lock.withLock {
      guard let value else { return }
      let json: JSONValue = [
        "access_token": .string(value.accessToken), "refresh_token": .string(value.refreshToken),
        "expires_at": value.expiresAt.map { .number($0) } ?? .null, "provider": .string(value.provider),
      ]
      try? json.data().write(to: url, options: .atomic)
    }
  }
}
