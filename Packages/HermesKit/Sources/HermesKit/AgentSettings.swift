import Foundation

/// Models starred in the model chooser. The desktop app keeps them in the Mac's shared UI
/// preferences (`/api/ui-preferences`) under `preferenceKey`, as a JSON array of
/// `provider::model` keys, first starred first. Writing the same key there makes a star on the
/// phone show in the desktop app and the other way round.
public enum FavoriteModels {
  public static let preferenceKey = "hermes.desktop.favorite-models"

  /// `anthropic::claude-opus-5-5`: the desktop app's key for a provider and model.
  public static func key(provider: String, model: String) -> String { "\(provider)::\(model)" }

  /// The provider and model of a key. The model part may itself contain `::`.
  public static func parts(_ key: String) -> (provider: String, model: String)? {
    guard let range = key.range(of: "::") else { return nil }
    let provider = String(key[..<range.lowerBound])
    let model = String(key[range.upperBound...])
    guard !provider.isEmpty, !model.isEmpty else { return nil }
    return (provider, model)
  }

  /// The stored value as a list, in order, without repeats. Anything unreadable is empty.
  public static func decode(_ raw: String?) -> [String] {
    guard let raw, let data = raw.data(using: .utf8),
      let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return [] }
    var seen = Set<String>()
    var keys: [String] = []
    for case let key as String in list where !key.isEmpty && seen.insert(key).inserted {
      keys.append(key)
    }
    return keys
  }

  /// The value to store. Nil for an empty list: the desktop app clears the key then.
  public static func encode(_ keys: [String]) -> String? {
    var seen = Set<String>()
    let unique = keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !unique.isEmpty else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(unique) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Stars a model at the end of the list, or takes its star away.
  public static func toggled(_ keys: [String], provider: String, model: String) -> [String] {
    let key = key(provider: provider, model: model)
    return keys.contains(key) ? keys.filter { $0 != key } : keys + [key]
  }
}

/// A bot's model catalog as its default sees it (`GET /api/model/options?profile=`): the same
/// providers as a chat's `model.options`, with the bot's default model and provider.
public struct ModelCatalog: Sendable, Equatable {
  public var providers: [ModelProvider]
  public var model: String
  public var provider: String

  public init(json: JSONValue) {
    providers = ModelProvider.catalog(from: json)
    model = json["model"].stringValue
    provider = json["provider"].stringValue
  }

  public init(providers: [ModelProvider], model: String, provider: String) {
    self.providers = providers
    self.model = model
    self.provider = provider
  }
}

/// What `POST /api/model/set` answered: saved, or an expensive model that needs a yes first.
public struct DefaultModelResult: Sendable, Equatable {
  public var needsConfirmation: Bool
  public var confirmationMessage: String
  public var provider: String
  public var model: String
  /// A note about usage limits some plans attach to the model.
  public var notice: String

  public init(json: JSONValue, provider: String, model: String) {
    needsConfirmation = json["confirm_required"].truthy
    confirmationMessage = json["confirm_message"].stringValue
    self.provider = json["provider"].string ?? provider
    self.model = json["model"].string ?? model
    notice = json["notice"].stringValue
  }
}

/// One category of a bot's installed skills, names sorted.
public struct SkillCategory: Identifiable, Sendable, Equatable {
  public var id: String { name }
  public let name: String
  public let skills: [String]

  public init(name: String, skills: [String]) {
    self.name = name
    self.skills = skills
  }

  /// `skills.manage {action: list}` answers `{skills: {category: [names]}}`. Categories sorted,
  /// with skills that have none (an empty category name) last.
  public static func list(from json: JSONValue) -> [SkillCategory] {
    guard let map = json["skills"].object else { return [] }
    return map.map { name, names in
      SkillCategory(name: name, skills: (names.array ?? []).compactMap(\.string).sorted())
    }
    .filter { !$0.skills.isEmpty }
    .sorted { a, b in
      if a.name.isEmpty != b.name.isEmpty { return !a.name.isEmpty }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }

  /// "autonomous-ai-agents" reads as "Autonomous AI agents".
  public var title: String {
    guard !name.isEmpty else { return "Other" }
    let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    let upper: Set<String> = ["ai", "mcp", "ios", "pdf", "api", "ui", "llm", "cli"]
    return words.enumerated().map { index, word in
      if upper.contains(word.lowercased()) { return word.uppercased() }
      return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
    }.joined(separator: " ")
  }
}

extension HermesClient {
  // MARK: Shared UI preferences

  /// The Mac's shared UI preferences, the desktop app's machine-wide settings, as raw strings.
  public func uiPreferences() async throws -> [String: String] {
    let json = try await http.json("GET", "/api/ui-preferences", timeout: 20)
    return (json["values"].object ?? [:]).compactMapValues(\.string)
  }

  /// Writes some keys of the shared UI preferences. A nil value deletes the key.
  public func setUIPreferences(_ values: [String: String?]) async throws {
    let fields = values.mapValues { value -> JSONValue in value.map(JSONValue.string) ?? .null }
    try await http.json("PATCH", "/api/ui-preferences", body: .object(["values": .object(fields)]), timeout: 20)
  }

  // MARK: A bot's default model

  /// The model catalog for a bot's default, without opening a chat.
  public func modelCatalog(profile: String) async throws -> ModelCatalog {
    ModelCatalog(json: try await http.json("GET", "/api/model/options", query: [("profile", profile)], timeout: 60))
  }

  /// Makes a model the bot's default for new chats (its config.yaml on the Mac). Chats already
  /// open keep their model. An expensive model comes back needing `confirmed`.
  public func setDefaultModel(profile: String, provider: String, model: String, confirmed: Bool = false) async throws
    -> DefaultModelResult
  {
    var body: [String: JSONValue] = ["scope": .string("main"), "provider": .string(provider), "model": .string(model)]
    if confirmed { body["confirm_expensive_model"] = .bool(true) }
    let json = try await http.json("POST", "/api/model/set", query: [("profile", profile)], body: .object(body), timeout: 60)
    let result = DefaultModelResult(json: json, provider: provider, model: model)
    if !result.needsConfirmation, !json["ok"].truthy {
      throw HermesError.invalidResponse(json["detail"].string ?? json["error"].string ?? "The Mac did not save the model")
    }
    return result
  }

  // MARK: Skills

  /// A bot's installed skills by category.
  public func skills(profile: String) async throws -> [SkillCategory] {
    try await rpc.waitUntilReady(timeout: 30)
    let json = try await rpc.call("skills.manage", ["action": .string("list"), "profile": .string(profile)], timeout: 30)
    return SkillCategory.list(from: json)
  }
}
