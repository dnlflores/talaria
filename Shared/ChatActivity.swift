import ActivityKit
import Foundation

/// A reply running in one chat, on the Lock Screen and in the Dynamic Island.
///
/// The Mac starts, updates and ends these with ActivityKit pushes (the `talaria-push` Hermes
/// plugin in `mac/`), so the property names are a wire format: the plugin sends `attributes` and
/// `content-state` with exactly these keys, and `attributes-type` is this type's name.
struct ChatActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var phase: Phase
    /// When the reply started, in seconds since 1970.
    var startedAt: Double
    /// When it ended, once it has.
    var endedAt: Double?
    /// What it is doing now ("Running a command"), or the question it is asking.
    var step: String?
    /// The start of the answer, once it has finished.
    var summary: String?
    /// The chat's title now. New chats get theirs after the reply starts, so it rides here too
    /// and wins over `ChatActivityAttributes.chatTitle`, which cannot change.
    var title: String?

    init(
      phase: Phase, startedAt: Double, endedAt: Double? = nil, step: String? = nil, summary: String? = nil,
      title: String? = nil
    ) {
      self.phase = phase
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.step = step
      self.summary = summary
      self.title = title
    }

    var startDate: Date { Date(timeIntervalSince1970: startedAt) }
    var endDate: Date? { endedAt.map(Date.init(timeIntervalSince1970:)) }
    var isOver: Bool { phase == .done || phase == .failed || phase == .stopped }
  }

  enum Phase: String, Codable, Hashable {
    case working, waiting, done, failed, stopped

    /// A phase a newer Mac sends that this build does not know reads as working, rather than
    /// dropping the whole update.
    init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      self = Phase(rawValue: raw) ?? .working
    }
  }

  /// The bot (Hermes profile) the chat belongs to.
  var profile: String
  /// The chat's stored id.
  var sessionID: String
  var botName: String
  var chatTitle: String

  /// The title to show: the newest one the Mac sent, else the one the activity started with.
  func displayTitle(_ state: ContentState) -> String {
    let title = (state.title ?? chatTitle).trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "New chat" : title
  }

  /// Opens the chat in the app.
  var url: URL {
    var components = URLComponents()
    components.scheme = "talaria"
    components.host = "chat"
    components.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "session", value: sessionID)]
    return components.url ?? URL(string: "talaria://")!
  }
}
