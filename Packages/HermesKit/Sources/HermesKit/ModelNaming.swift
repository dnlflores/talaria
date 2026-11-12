import Foundation

/// A model id as people read it: `claude-opus-4-5-20251101` is "Opus 4.5", `gpt-6.1-sol-900k`
/// is "GPT-6.1 Sol" with a "900K" tag. The rules follow the Hermes desktop app's model labels,
/// so both apps name a model the same way.
public struct ModelName: Sendable, Equatable {
  public let id: String
  /// The name without its variant tags.
  public let name: String
  /// Variants of the same model that the id carries: Fast, Flash, Thinking, Preview, Latest,
  /// a quantization (Q4) or a context window (1M, 900K).
  public let tags: [String]
  /// The vendor in a routed id (`anthropic` in `anthropic/claude-opus-5`), else empty.
  public let vendor: String
  /// The name without its version, for keeping a line of models together.
  public let family: String
  /// The version numbers in the name (`[4, 5]` for "Opus 4.5"); empty when there are none.
  public let version: [Int]

  /// Name and tags on one line.
  public var display: String { tags.isEmpty ? name : "\(name) \(tags.joined(separator: " "))" }

  public init(_ id: String) {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = trimmed
    var base = trimmed
    var vendor = ""
    if let slash = trimmed.lastIndex(of: "/") {
      base = String(trimmed[trimmed.index(after: slash)...])
      vendor = String(trimmed[..<slash])
    }
    self.vendor = vendor

    var variant = ""
    var quant = ""
    var progress = true
    while progress {
      progress = false
      if variant.isEmpty {
        for (suffix, label) in ModelName.variants where base.lowercased().hasSuffix(suffix) {
          variant = label
          base = String(base.dropLast(suffix.count))
          progress = true
          break
        }
      }
      if quant.isEmpty, let match = base.firstMatch(of: ModelName.quantPattern) {
        quant = String(match.output.1).split(separator: "_").first.map { $0.uppercased() } ?? ""
        base = String(base[..<match.range.lowerBound])
        base = base.replacing(/(?i)-(?:Instruct|Chat)(?:-\d{4})?$/, with: "")
        progress = true
      }
    }
    var context = ""
    if let match = base.firstMatch(of: /\[(\d+[mMkK])\]$/) {
      context = match.output.1.uppercased()
      base = String(base[..<match.range.lowerBound])
    } else if let match = base.firstMatch(of: /-(\d+[mMkK])$/) {
      context = match.output.1.uppercased()
      base = String(base[..<match.range.lowerBound])
    }
    // A date pin (`-20251101`) is a snapshot of the same model, not part of its name.
    base = base.replacing(/-\d{8}$/, with: "")

    tags = [variant, quant, context].filter { !$0.isEmpty }
    let pretty = ModelName.prettify(base)
    name = pretty.isEmpty ? (trimmed.isEmpty ? "No model" : trimmed) : pretty
    (family, version) = ModelName.familyAndVersion(of: name)
  }

  private static let variants: [(String, String)] = [
    ("-fast", "Fast"), ("-flash", "Flash"), ("-thinking", "Thinking"), ("-preview", "Preview"), ("-latest", "Latest"),
  ]

  nonisolated(unsafe) private static let quantPattern = /(?i)-(?:UD-)?(Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$/

  private static func prettify(_ base: String) -> String {
    let lower = base.lowercased()
    if lower.hasPrefix("claude-") {
      // Anthropic writes the version with hyphens (`opus-4-5`); people say "Opus 4.5".
      let rest = String(base.dropFirst(7)).replacing(/(\d)-(?=\d)/) { "\($0.output.1)." }
      return casing(titleCase(rest.replacingOccurrences(of: "-", with: " ")))
    }
    if lower.hasPrefix("gpt-") {
      let parts = base.dropFirst(4).split(separator: "-").map(String.init)
      guard let first = parts.first else { return "GPT" }
      let rest = parts.dropFirst().joined(separator: " ")
      if first.first?.isNumber == true {
        return rest.isEmpty ? "GPT-\(first)" : "GPT-\(first) \(casing(titleCase(rest)))"
      }
      return "GPT " + casing(titleCase(parts.joined(separator: " ")))
    }
    return casing(titleCase(base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")))
  }

  private static func titleCase(_ text: String) -> String {
    text.split(separator: " ", omittingEmptySubsequences: true).map { word in
      guard let first = word.first, first.isLetter else { return String(word) }
      return first.uppercased() + word.dropFirst()
    }.joined(separator: " ")
  }

  /// Vendors' own spellings, and parameter counts as vendors write them (8B, A3B).
  private static func casing(_ text: String) -> String {
    let words: [String: String] = [
      "Deepseek": "DeepSeek", "Glm": "GLM", "Minimax": "MiniMax", "Openai": "OpenAI", "Ernie": "ERNIE",
      "Mimo": "MiMo", "Oss": "OSS", "Vl": "VL", "Fp8": "FP8", "Ai": "AI", "It": "IT",
    ]
    return text.split(separator: " ").map { word -> String in
      let token = String(word)
      if let known = words[token] { return known }
      if token.wholeMatch(of: /(?i)a?\d+(?:\.\d+)?b/) != nil { return token.uppercased() }
      return token
    }.joined(separator: " ")
  }

  /// The first token that reads as a version ("5.5", "V4.1", "GPT-6.1", the "3.6" of "Qwen3.6").
  /// Parameter counts like "120B" are not versions.
  private static func familyAndVersion(of name: String) -> (String, [Int]) {
    var tokens = name.split(separator: " ").map(String.init)
    for (index, token) in tokens.enumerated() {
      var prefix = ""
      var digits: Substring?
      if let match = token.wholeMatch(of: /(?i)(GPT-|v)?(\d+(?:\.\d+)*)/) {
        prefix = match.output.1.map { $0.lowercased() == "v" ? "" : "GPT" } ?? ""
        digits = match.output.2
      } else if let match = token.wholeMatch(of: /([A-Za-z]+)(\d+(?:\.\d+)*)/) {
        prefix = String(match.output.1)
        digits = match.output.2
      }
      guard let digits else { continue }
      let version = digits.split(separator: ".").compactMap { Int($0) }
      if prefix.isEmpty { tokens.remove(at: index) } else { tokens[index] = prefix }
      return (tokens.joined(separator: " "), version)
    }
    return (name, [])
  }

  /// A vendor prefix as a heading: `x-ai` is "xAI".
  public static func vendorTitle(_ vendor: String) -> String {
    let known: [String: String] = [
      "anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "x-ai": "xAI", "xai": "xAI",
      "deepseek": "DeepSeek", "meta-llama": "Meta", "mistralai": "Mistral", "qwen": "Qwen",
      "moonshotai": "Moonshot", "z-ai": "Z.ai", "minimax": "MiniMax", "nousresearch": "Nous Research",
    ]
    let key = vendor.lowercased()
    if let title = known[key] { return title }
    return titleCase(key.replacingOccurrences(of: "-", with: " "))
  }
}

extension ModelProvider {
  /// A run of models under one heading in a provider's list.
  public struct Section: Identifiable, Sendable, Equatable {
    public var id: String { title }
    /// Empty for a provider that serves one vendor's models.
    public let title: String
    public let models: [Model]
  }

  /// Whether this plan can use the model (a free tier lists models it does not include).
  public func isAvailable(_ model: Model) -> Bool { !unavailable.contains(model.name) }

  public var availableModels: [Model] { models.filter(isAvailable) }

  /// The models this plan does not include, newest first.
  public var lockedModels: [Model] { ModelProvider.ordered(models.filter { !isAvailable($0) }) }

  /// The models this plan can use, newest first within each line of models. A provider that
  /// routes to several vendors (`anthropic/…`, `openai/…`) gets a heading per vendor.
  public var sections: [Section] {
    let usable = availableModels
    guard usable.contains(where: { $0.name.contains("/") }) else {
      return usable.isEmpty ? [] : [Section(title: "", models: ModelProvider.ordered(usable))]
    }
    var order: [String] = []
    var byVendor: [String: [Model]] = [:]
    for model in usable {
      let vendor = ModelName(model.name).vendor
      if byVendor[vendor] == nil { order.append(vendor) }
      byVendor[vendor, default: []].append(model)
    }
    return order.map { vendor in
      Section(title: vendor.isEmpty ? "Other" : ModelName.vendorTitle(vendor), models: ModelProvider.ordered(byVendor[vendor] ?? []))
    }
  }

  /// Each line of models together (Opus, Sonnet, ...), newest first; lines ordered by their
  /// newest model; a model's tagged variants (Fast, 900K) right after it.
  public static func ordered(_ models: [Model]) -> [Model] {
    let named = models.enumerated().map { (index: $0.offset, model: $0.element, name: ModelName($0.element.name)) }
    var families: [String] = []
    var newest: [String: [Int]] = [:]
    for entry in named {
      if newest[entry.name.family] == nil { families.append(entry.name.family) }
      if isNewer(entry.name.version, than: newest[entry.name.family] ?? []) { newest[entry.name.family] = entry.name.version }
    }
    let familyOrder = Dictionary(uniqueKeysWithValues: families.enumerated().map { ($0.element, $0.offset) })
    return named.sorted { a, b in
      let (fa, fb) = (a.name.family, b.name.family)
      if fa != fb {
        let (na, nb) = (newest[fa] ?? [], newest[fb] ?? [])
        if na != nb { return isNewer(na, than: nb) }
        return (familyOrder[fa] ?? 0) < (familyOrder[fb] ?? 0)
      }
      if a.name.version != b.name.version { return isNewer(a.name.version, than: b.name.version) }
      if a.name.tags.count != b.name.tags.count { return a.name.tags.count < b.name.tags.count }
      return a.index < b.index
    }.map(\.model)
  }

  private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
    for index in 0..<max(a.count, b.count) {
      let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
      if x != y { return x > y }
    }
    return false
  }
}
