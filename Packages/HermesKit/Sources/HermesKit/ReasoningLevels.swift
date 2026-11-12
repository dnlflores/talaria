import Foundation

/// The thinking efforts one model offers, each listed once.
///
/// Hermes has one ladder (Off, Minimal, Low, Medium, High, Extra high, Max, Ultra) and every route
/// fits it to what the model accepts, so several rungs can send the same request: on Opus 4.6
/// Extra high sends Max, on Opus 4.5 Max gets Medium's thinking budget, and Opus 5.5 cannot turn
/// thinking off. The backend does not publish these rules, so they are ported from Hermes itself
/// (`agent/reasoning_effort.py`, `agent/anthropic_adapter.py`, `agent/transports/codex.py`, the
/// custom provider profile). A level is listed once per distinct request.
public struct ReasoningLevels: Sendable, Equatable {
  public struct Level: Sendable, Equatable, Identifiable {
    public var id: String { effort }
    /// What is sent to Hermes when this level is picked; "none" is Off.
    public let effort: String
    /// Other rungs of the ladder that send the same request ("ultra" behind Max).
    public let sameAs: [String]

    public var label: String { ReasoningLevels.label(effort) }
    public var shortLabel: String { ReasoningLevels.shortLabel(effort) }
  }

  /// Off first when the model can turn thinking off, then weakest to strongest. Empty when the
  /// model takes no effort at all.
  public let levels: [Level]

  public var isEmpty: Bool { levels.isEmpty }
  public var canTurnOff: Bool { levels.first?.effort == "none" }

  /// Hermes's level when a conversation has none set.
  public static let defaultEffort = "medium"

  /// The level a conversation's effort is shown as: its own, or the one sending the same request.
  public func level(for effort: String) -> Level? {
    let value = effort.trimmingCharacters(in: .whitespaces).lowercased()
    let wanted = value.isEmpty ? Self.defaultEffort : value
    return levels.first { $0.effort == wanted || $0.sameAs.contains(wanted) }
  }

  /// - Parameters:
  ///   - canDisableReasoning: the catalog's `can_disable_reasoning`; only aggregators report it.
  public init(provider: String, model: String, supportsReasoning: Bool, canDisableReasoning: Bool? = nil) {
    guard supportsReasoning else {
      levels = []
      return
    }
    let slug = provider.lowercased()
    let bare = String(model.lowercased().split(separator: "/").last ?? "")
    let route: Route
    if slug == "anthropic", bare.hasPrefix("claude") {
      route = Self.anthropic(bare.replacingOccurrences(of: ".", with: "-"))
    } else if slug == "openai-codex" {
      route = Self.codex(bare)
    } else if slug == "antigravity-agy" {
      // The agy CLI takes the effort from the model's name (gemini-3.8-flash-low) and ignores the knob.
      route = .none
    } else {
      // Every other route sends the OpenAI-compatible set: none..max, Ultra sends Max.
      route = .sends({ Self.clamp($0, to: Self.openAICompat) }, off: canDisableReasoning != false)
    }
    levels = Self.levels(for: route)
  }

  public init(levels: [Level]) { self.levels = levels }

  // MARK: Labels

  public static func label(_ effort: String) -> String {
    switch effort.lowercased() {
    case "none": return "Off"
    case "xhigh": return "Extra high"
    case "": return ""
    default: return effort.prefix(1).uppercased() + effort.dropFirst().lowercased()
    }
  }

  /// For a row of segments too narrow for the full names.
  public static func shortLabel(_ effort: String) -> String {
    switch effort.lowercased() {
    case "minimal": return "Min"
    case "medium": return "Med"
    case "xhigh": return "X-High"
    default: return label(effort)
    }
  }

  // MARK: Hermes's rules

  /// The ladder above Off, weakest first.
  static let ladder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
  private static let ladderWithOff = ["none"] + ladder
  static let openAICompat = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

  enum Route {
    case none
    /// What each rung sends on this route; rungs sending the same thing are one level.
    case sends((String) -> String, off: Bool)
  }

  /// `clamp_effort`: a supported level as is, else the nearest weaker one (never Off), else the
  /// weakest supported.
  static func clamp(_ effort: String, to supported: [String]) -> String {
    if supported.contains(effort) { return effort }
    guard let index = ladderWithOff.firstIndex(of: effort) else { return effort }
    let candidates = supported.filter { $0 != "none" }
    guard !candidates.isEmpty else { return effort }
    let below = candidates.filter { (ladderWithOff.firstIndex(of: $0) ?? 0) < index }
    let rank = { (level: String) in ladderWithOff.firstIndex(of: level) ?? 0 }
    return below.max { rank($0) < rank($1) } ?? candidates.min { rank($0) < rank($1) }!
  }

  /// Anthropic Messages. Claude 4.6+ think adaptively with a named effort; older models get a
  /// token budget; Haiku before 5.5 never thinks.
  static func anthropic(_ model: String) -> Route {
    let legacy = [
      "claude-3", "claude-opus-4-0", "claude-opus-4-1", "claude-sonnet-4-0", "claude-opus-4-2025",
      "claude-sonnet-4-2025", "claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5",
    ]
    if model.contains("haiku") {
      let version = claudeVersion(model)
      if version == nil || version!.family != "haiku" || (version!.major, version!.minor) < (5, 5) { return .none }
    }
    if legacy.contains(where: model.contains) {
      // Budgets for low..xhigh; any other rung falls back to Medium's 8000 tokens.
      let budgets = ["low": "4000", "medium": "8000", "high": "16000", "xhigh": "32000"]
      return .sends({ budgets[$0] ?? "8000" }, off: true)
    }
    let noExtraHigh = ["claude-opus-4-6", "claude-sonnet-4-6"]
    let adaptive = ["ultra": "max", "max": "max", "xhigh": "xhigh", "high": "high", "medium": "medium", "low": "low", "minimal": "low"]
    // These 400 on a disable; Hermes then leaves thinking on. Sonnet 5.5's "off" thinks only between tools.
    let alwaysThinks = ["claude-fable", "claude-mythos", "claude-opus-5-5"]
    return .sends({ effort in
      let sent = adaptive[effort] ?? "medium"
      return sent == "xhigh" && noExtraHigh.contains(where: model.contains) ? "max" : sent
    }, off: !alwaysThinks.contains(where: model.contains))
  }

  /// OpenAI Responses through the Codex backend, per model generation.
  static func codex(_ model: String) -> Route {
    let astra = ["gpt-6-astra", "gpt-6-astra-900k"].contains(model) || model.hasPrefix("gpt-6.1-sol")
    let daybreak = ["gpt-daybreak-blue-latest", "gpt-daybreak-blue-latest-900k"].contains(model)
    let supported: [String]
    if astra {
      supported = ["low", "medium", "high", "xhigh", "max"]
    } else if model.contains("gpt-5.6") || model.hasPrefix("gpt-6-sol") || model.hasPrefix("gpt-6-luna") || daybreak {
      supported = ["none", "low", "medium", "high", "xhigh", "max"]
    } else {
      supported = ["none", "low", "medium", "high", "xhigh"]
    }
    return .sends({ clamp($0, to: supported) }, off: supported.contains("none"))
  }

  /// `claude_family_version`: "claude-opus-4-5-20251101" is opus 4.5; a date is not a minor.
  static func claudeVersion(_ model: String) -> (family: String, major: Int, minor: Int)? {
    guard let match = model.firstMatch(of: /claude[-_.](opus|sonnet|haiku|fable|mythos)[-_.](\d+)(?:[-_.](\d{1,2})(?=$|[-_.]))?/)
    else { return nil }
    return (String(match.output.1), Int(match.output.2) ?? 0, match.output.3.flatMap { Int($0) } ?? 0)
  }

  static func levels(for route: Route) -> [Level] {
    guard case .sends(let sends, let off) = route else { return [] }
    var order: [String] = []
    var members: [String: [String]] = [:]
    for rung in ladder {
      let key = sends(rung)
      if members[key] == nil { order.append(key) }
      members[key, default: []].append(rung)
    }
    let prefer = ["low", "medium", "high", "xhigh", "max", "minimal", "ultra"]
    var levels = order.map { key -> Level in
      let group = members[key] ?? []
      let shown = group.contains(key) ? key : prefer.first(where: group.contains) ?? group[0]
      return Level(effort: shown, sameAs: group.filter { $0 != shown })
    }
    levels.sort { (ladder.firstIndex(of: $0.effort) ?? 0) < (ladder.firstIndex(of: $1.effort) ?? 0) }
    return off ? [Level(effort: "none", sameAs: [])] + levels : levels
  }
}
