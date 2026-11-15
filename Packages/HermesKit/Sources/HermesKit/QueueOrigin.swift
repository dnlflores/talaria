import Foundation

/// Which app, on which device, put a message in a chat's queue on the Mac.
///
/// The gateway keeps no record of who queued what: a queued row carries only the submission id
/// its sender chose (`input_id`). So Talaria writes its device into that id
/// (`talaria.iphone.<uuid>`) and reads it back from every row, its own and other devices'.
/// The desktop app sends a bare UUID and the terminal a bare 32-digit hex id; anything else is
/// some other app.
public enum QueueOrigin: Equatable, Sendable {
  /// Talaria on a device of this kind ("iPhone", "iPad").
  case talaria(device: String)
  case desktop
  case terminal
  case unknown

  private static let marker = "talaria."

  /// A fresh submission id naming this device, e.g. `talaria.iphone.<uuid>`.
  public static func submissionID(device: String?) -> String {
    let uuid = UUID().uuidString.lowercased()
    guard let device, !device.isEmpty else { return uuid }
    return marker + slug(device) + "." + uuid
  }

  /// A new id from the same device, for a message whose last admission was cancelled.
  public static func renewed(_ old: String) -> String {
    if case .talaria(let device) = QueueOrigin(inputID: old) { return submissionID(device: device) }
    return UUID().uuidString.lowercased()
  }

  public init(inputID: String) {
    if inputID.hasPrefix(Self.marker) {
      let parts = inputID.dropFirst(Self.marker.count).split(separator: ".", maxSplits: 1)
      if parts.count == 2, !parts[0].isEmpty {
        self = .talaria(device: Self.name(String(parts[0])))
        return
      }
    }
    if UUID(uuidString: inputID) != nil {
      self = .desktop
    } else if inputID.count == 32, inputID.allSatisfy(\.isHexDigit) {
      self = .terminal
    } else {
      self = .unknown
    }
  }

  /// What the queue shows: "iPhone", "iPad", "Hermes desktop", "Terminal", "Another app".
  public var label: String {
    switch self {
    case .talaria(let device): device
    case .desktop: "Hermes desktop"
    case .terminal: "Terminal"
    case .unknown: "Another app"
    }
  }

  private static func slug(_ device: String) -> String {
    let lowered = device.lowercased().replacingOccurrences(of: " ", with: "-")
    let kept = lowered.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return kept.isEmpty ? "device" : kept
  }

  private static func name(_ slug: String) -> String {
    switch slug {
    case "iphone": "iPhone"
    case "ipad": "iPad"
    case "iphone-duo": "iPhone Duo"
    case "mac": "Mac"
    default: slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
  }
}

/// One message waiting in a chat's queue on the Mac, as the gateway lists it (`pending` on a
/// resume and on every `session.info` that changes the queue). It may be from any device.
public struct QueuedOnMac: Identifiable, Equatable, Sendable {
  public let admissionID: String
  /// The submission id its sender chose; says which device sent it (`QueueOrigin`).
  public let inputID: String
  public let text: String
  /// `queued`, or `started` while it is being handed to the running reply.
  public let status: String
  /// What the Mac lets any viewer do with it: `steer` (into the running reply), `replace`.
  /// Text-only messages get both; ones with photos get none.
  public let controls: [String]
  /// Being handed to the running reply right now (`prompt.steer_queued`).
  public let isSteering: Bool

  public var id: String { admissionID }
  public var origin: QueueOrigin { QueueOrigin(inputID: inputID) }
  public var isWaiting: Bool { status == "queued" && !isSteering }
  public var canSteer: Bool { controls.contains("steer") }

  public init(admissionID: String, inputID: String, text: String, status: String = "queued",
              controls: [String] = [], isSteering: Bool = false) {
    self.admissionID = admissionID
    self.inputID = inputID
    self.text = text
    self.status = status
    self.controls = controls
    self.isSteering = isSteering
  }

  /// The rows in a `pending` array; nil when the payload has none (an older gateway, or a
  /// `session.info` about something else).
  public static func list(_ pending: JSONValue) -> [QueuedOnMac]? {
    guard let rows = pending.array else { return nil }
    return rows.compactMap { row in
      guard let admissionID = row["admission_id"].string else { return nil }
      return QueuedOnMac(
        admissionID: admissionID, inputID: row["input_id"].stringValue, text: row["text"].stringValue,
        status: row["status"].stringValue, controls: row["controls"].array?.compactMap(\.string) ?? [],
        isSteering: row["steering"].truthy)
    }
  }
}
