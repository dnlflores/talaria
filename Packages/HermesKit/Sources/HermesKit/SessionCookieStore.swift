import Foundation
import Security

/// Holds the gate's session cookie value (`hd_session`) per endpoint.
///
/// The app never stores the password: signing in trades it for this cookie,
/// which the gate signs and expires on its own schedule.
public protocol SessionCookieStore: Sendable {
  func cookie(for endpoint: ServerEndpoint) -> String?
  func setCookie(_ value: String?, for endpoint: ServerEndpoint)
}

public final class InMemoryCookieStore: SessionCookieStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]

  public init() {}

  public func cookie(for endpoint: ServerEndpoint) -> String? {
    lock.withLock { values[endpoint.origin] }
  }

  public func setCookie(_ value: String?, for endpoint: ServerEndpoint) {
    lock.withLock { values[endpoint.origin] = value }
  }
}

/// Keychain-backed store: one generic-password item per endpoint origin.
public struct KeychainCookieStore: SessionCookieStore {
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

  public func cookie(for endpoint: ServerEndpoint) -> String? {
    var request = query(endpoint)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func setCookie(_ value: String?, for endpoint: ServerEndpoint) {
    SecItemDelete(query(endpoint) as CFDictionary)
    guard let value, !value.isEmpty else { return }
    var item = query(endpoint)
    item[kSecValueData as String] = Data(value.utf8)
    // Readable after the first unlock so a reconnect while the phone is locked still works.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }
}
