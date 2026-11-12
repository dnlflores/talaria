import Foundation

public enum HermesError: Error, Sendable, Equatable {
  /// The gate wants the password (no cookie, or the cookie expired).
  case loginRequired
  case wrongPassword
  case tooManyAttempts
  /// The Mac has no dashboard password set yet (`hermesdash password`).
  case noPasswordConfigured
  /// The address answered, but not like a Hermes gate.
  case notAHermesGate(String)
  case http(status: Int, message: String)
  case rpc(code: Int, message: String, reason: String?)
  case notConnected
  case timedOut(String)
  case invalidResponse(String)
  case transport(String)
}

extension HermesError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .loginRequired: return "Sign in to your Mac to continue."
    case .wrongPassword: return "Wrong password."
    case .tooManyAttempts: return "Too many attempts. Try again in a few minutes."
    case .noPasswordConfigured: return "No password is set on the Mac yet. Run `hermesdash password` there first."
    case .notAHermesGate(let detail): return "That address did not answer like a Hermes gate (\(detail))."
    case .http(let status, let message): return message.isEmpty ? "The Mac answered with HTTP \(status)." : message
    case .rpc(_, let message, _): return message
    case .notConnected: return "Not connected to the Mac."
    case .timedOut(let what): return "\(what) timed out."
    case .invalidResponse(let detail): return "Unexpected answer from the Mac: \(detail)"
    case .transport(let detail): return detail
    }
  }
}

extension HermesError {
  /// The live session id is unknown to the backend (reaped, or never existed here).
  public var isSessionGone: Bool {
    guard case .rpc(let code, let message, _) = self else { return false }
    if code == 4001 || code == 4007 { return true }
    let text = message.lowercased()
    return text.contains("session not found") || text.contains("unknown session") || text.contains("no such session")
  }

  public var isConnectionLoss: Bool {
    switch self {
    case .notConnected: return true
    case .transport: return true
    default: return false
    }
  }

  /// Another Hermes process on the Mac (the desktop app, a terminal) holds this chat,
  /// so the backend refused the turn.
  public var isOwnedElsewhere: Bool {
    guard case .rpc(_, let message, let reason) = self else { return false }
    return reason == "SESSION_NOT_OWNED" || HermesError.looksOwnedElsewhere(message)
  }

  public static func looksOwnedElsewhere(_ message: String) -> Bool {
    let text = message.lowercased()
    return text.contains("open in another hermes") || text.contains("session_not_owned")
      || text.contains("already has a live owner") || text.contains("already held by")
  }

  static func wrap(_ error: any Error) -> HermesError {
    if let known = error as? HermesError { return known }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
      switch ns.code {
      case NSURLErrorTimedOut: return .timedOut("The request")
      case NSURLErrorCancelled: return .transport("Cancelled.")
      default: return .transport(ns.localizedDescription)
      }
    }
    return .transport(ns.localizedDescription)
  }
}
