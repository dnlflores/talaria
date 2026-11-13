import Foundation

/// What the phone tells the `talaria-push` Hermes plugin on the Mac (`mac/talaria-push` in this
/// repository), which watches every chat and sends the notifications and Live Activity pushes.
public struct PushRegistration: Sendable, Equatable {
  /// Which chats notify.
  public enum Scope: String, Sendable, CaseIterable, Identifiable {
    /// Every chat on every bot (the desktop app's and terminal chats included).
    case all
    /// Only chats this phone sent a message to in the last day.
    case phone

    public var id: String { rawValue }
  }

  /// Stable per install (`identifierForVendor`).
  public var deviceID: String
  public var name: String
  /// The APNs device token, hex. Nil until iOS hands one over.
  public var token: String?
  /// ActivityKit's push-to-start token, hex: lets the Mac start a Live Activity on its own.
  public var pushToStartToken: String?
  /// `development` (Xcode-signed builds, the sandbox APNs host) or `production`.
  public var environment: String
  /// The app's bundle id: the APNs topic.
  public var topic: String
  /// The team that signed the app. The Mac's APNs key belongs to it.
  public var teamID: String?
  public var alerts: Bool
  public var liveActivities: Bool
  public var scope: Scope
  /// Bot titles by profile name, so pushes say "Ada finished" rather than "ada finished".
  public var bots: [String: String]

  public init(
    deviceID: String, name: String, token: String?, pushToStartToken: String?, environment: String, topic: String,
    teamID: String?, alerts: Bool, liveActivities: Bool, scope: Scope, bots: [String: String]
  ) {
    self.deviceID = deviceID
    self.name = name
    self.token = token
    self.pushToStartToken = pushToStartToken
    self.environment = environment
    self.topic = topic
    self.teamID = teamID
    self.alerts = alerts
    self.liveActivities = liveActivities
    self.scope = scope
    self.bots = bots
  }

  public var body: JSONValue {
    .fields([
      "device_id": .string(deviceID),
      "name": .string(String(name.prefix(80))),
      "token": token.map(JSONValue.string),
      "push_to_start_token": pushToStartToken.map(JSONValue.string),
      "environment": .string(environment),
      "topic": .string(topic),
      "team_id": teamID.map(JSONValue.string),
      "alerts": .bool(alerts),
      "live_activities": .bool(liveActivities),
      "scope": .string(scope.rawValue),
      "bots": .object(bots.mapValues(JSONValue.string)),
    ])
  }

  /// A token as APNs and the plugin spell it.
  public static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}

/// How the app was signed, read from its embedded provisioning profile: which APNs host its
/// tokens belong to, and which team's key can reach them.
public struct SigningFacts: Sendable, Equatable {
  public var environment: String
  public var teamID: String?

  public init(environment: String, teamID: String?) {
    self.environment = environment
    self.teamID = teamID
  }

  /// `embedded.mobileprovision` is a signed CMS blob around a plain XML plist. App Store and
  /// TestFlight builds carry none: those use production. The simulator uses the sandbox.
  public static func from(provisioningProfile data: Data?, simulator: Bool) -> SigningFacts {
    let fallback = SigningFacts(environment: simulator ? "development" : "production", teamID: nil)
    guard let data, let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
    else { return fallback }
    let xml = data.subdata(in: start.lowerBound..<end.upperBound)
    guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
      return fallback
    }
    let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
    let environment = entitlements["aps-environment"] as? String ?? fallback.environment
    let team = (plist["TeamIdentifier"] as? [String])?.first
    return SigningFacts(environment: environment == "development" ? "development" : "production", teamID: team)
  }
}

/// What the Mac said about notifications.
public enum PushMacState: Sendable, Equatable {
  case unknown
  /// The plugin is not installed or not enabled on the Mac.
  case notInstalled
  /// Registered, but the Mac has no APNs key yet, so nothing can be sent.
  case needsKey
  case ready
  case failed(String)
}

/// The plugin's routes. On `HermesHTTP` rather than `HermesClient`: a Live Activity started by a push
/// wakes the app in the background, where only REST is wanted to hand its token over.
extension HermesHTTP {
  static let pushBase = "/api/plugins/talaria-push"

  /// Registers this phone. Returns what the Mac can do with it.
  public func registerPush(_ registration: PushRegistration) async throws -> PushMacState {
    do {
      let answer = try await json("POST", "\(Self.pushBase)/devices", body: registration.body, timeout: 20)
      return answer["apns_configured"].bool == true ? .ready : .needsKey
    } catch HermesError.http(let status, _) where status == 404 || status == 405 {
      return .notInstalled
    }
  }

  public func unregisterPush(deviceID: String) async throws {
    let escaped = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
    try await json("DELETE", "\(Self.pushBase)/devices/\(escaped)", timeout: 15)
  }

  /// A Live Activity's own update token, so the Mac can update and end it.
  public func registerActivity(deviceID: String, sessionID: String, profile: String, token: String) async throws {
    try await json(
      "POST", "\(Self.pushBase)/activities",
      body: ["device_id": .string(deviceID), "session_id": .string(sessionID), "profile": .string(profile), "token": .string(token)],
      timeout: 20)
  }

  /// This phone sent a message to the chat: with the "chats from this phone" setting, it notifies.
  public func followForPush(deviceID: String, sessionID: String) async throws {
    try await json(
      "POST", "\(Self.pushBase)/follow", body: ["device_id": .string(deviceID), "session_id": .string(sessionID)],
      timeout: 15)
  }

  /// Asks the Mac to send a test notification right now. Returns Apple's answer.
  public func sendTestPush(deviceID: String) async throws -> (ok: Bool, reason: String) {
    let answer = try await json("POST", "\(Self.pushBase)/test", body: ["device_id": .string(deviceID)], timeout: 40)
    return (answer["ok"].bool == true, answer["reason"].stringValue)
  }
}
