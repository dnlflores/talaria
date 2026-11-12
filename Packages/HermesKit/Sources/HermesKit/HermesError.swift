import Foundation

public enum HermesError: Error, Sendable, Equatable {
  /// Hermes on the Mac wants a sign-in (none held, or it ran out and could not be renewed).
  case loginRequired
  /// The person closed the sign-in sheet.
  case signInCancelled
  case signInFailed(String)
  /// The Mac asks for a sign-in but offers no provider to sign in with.
  case noSignInConfigured
  /// The address answered, but not like Hermes.
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
    case .loginRequired: return "Sign in to Hermes on your Mac to continue."
    case .signInCancelled: return "Sign-in was cancelled."
    case .signInFailed(let detail): return "Sign-in did not finish: \(detail)"
    case .noSignInConfigured:
      return "Hermes on the Mac has no sign-in set up for other devices. Turn on Web Access in the desktop app first."
    case .notAHermesGate(let detail): return "That address did not answer like Hermes (\(detail))."
    case .http(let status, let message): return message.isEmpty ? "The Mac answered with HTTP \(status)." : message
    case .rpc(_, let message, let reason): return HermesError.readable(message: message, reason: reason)
    case .notConnected: return "Not connected to the Mac."
    case .timedOut(let what): return "\(what) timed out."
    case .invalidResponse(let detail): return "Unexpected answer from the Mac: \(detail)"
    case .transport(let detail): return detail
    }
  }
}

extension HermesError {
  /// The live session id is unknown to the backend (reaped, or never existed here), or this
  /// connection is no longer attached to it (the gateway answers `permission_denied` to a socket
  /// that did not resume the chat, which is every socket after a reconnect).
  public var isSessionGone: Bool {
    guard case .rpc(let code, let message, let reason) = self else { return false }
    if let reason { return ["not_found", "permission_denied", "session_not_found"].contains(reason) }
    if code == 4001 || code == 4007 { return true }
    let text = message.lowercased()
    return text.contains("session not found") || text.contains("unknown session") || text.contains("no such session")
  }

  /// The gateway refused because the chat moved on since its fences were read (another viewer
  /// changed it, or a turn started or ended): read them again and retry once.
  public var isStaleFence: Bool {
    guard case .rpc(_, _, let reason) = self else { return false }
    return reason == "stale_generation" || reason == "revision_conflict"
  }

  /// The gateway answers with a bare reason code; say it in words.
  static func readable(message: String, reason: String?) -> String {
    let words: [String: String] = [
      "session_busy": "The chat is busy right now.",
      "stale_generation": "The chat changed on the Mac meanwhile. Try again.",
      "revision_conflict": "The chat changed on the Mac meanwhile. Try again.",
      "permission_denied": "The Mac refused that for this chat.",
      "not_found": "The chat is no longer on the Mac.",
      "invalid_params": "The Mac did not accept that request.",
      "runtime_draining": "Hermes on the Mac is restarting. Try again in a moment.",
      "queue_full": "Too many messages are waiting in this chat.",
      "storage_unavailable": "The Mac could not save that right now.",
    ]
    if let reason, message == reason || message.isEmpty, let text = words[reason] { return text }
    return message
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
