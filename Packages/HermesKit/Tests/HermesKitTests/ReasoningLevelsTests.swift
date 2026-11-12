import Foundation
import Testing

@testable import HermesKit

@Suite struct ReasoningLevelsTests {
  /// What Hermes's own request builders send for each rung, grouped: one entry per distinct
  /// request, the rungs after "+" send the same thing, "none" first when Off really turns thinking
  /// off. Recorded from the backend's code (anthropic_adapter, codex transport, chat-completions
  /// clamp, custom profile) for the models in a live catalog.
  static let recorded: [(provider: String, model: String, reasoning: Bool, canDisable: Bool?, levels: String)] = [
    ("anthropic", "claude-opus-4-5-20251101", true, nil, "none low medium+minimal+max+ultra high xhigh"),
    ("anthropic", "claude-opus-4-6", true, nil, "none low+minimal medium high max+xhigh+ultra"),
    ("anthropic", "claude-opus-4-7", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-opus-4-8", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-opus-5", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-opus-5-5", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-sonnet-4-5-20250929", true, nil, "none low medium+minimal+max+ultra high xhigh"),
    ("anthropic", "claude-sonnet-4-6", true, nil, "none low+minimal medium high max+xhigh+ultra"),
    ("anthropic", "claude-sonnet-5", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-sonnet-5-5", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-haiku-4-5-20251001", true, nil, ""),
    ("anthropic", "claude-haiku-5-5", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-fable-5", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-fable-5-1", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("anthropic", "claude-fable-5-2", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6.1-sol", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6.1-sol-900k", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6-astra", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6-astra-900k", true, nil, "low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6.1-terra", true, nil, "none low+minimal medium high xhigh+max+ultra"),
    ("openai-codex", "gpt-6-sol", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6-sol-900k", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6-luna", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-6-luna-900k", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-sol", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-sol-900k", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-terra", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-terra-900k", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-luna", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("openai-codex", "gpt-5.6-luna-900k", true, nil, "none low+minimal medium high xhigh max+ultra"),
    ("nous", "anthropic/claude-fable-5.2", true, false, "minimal low medium high xhigh max+ultra"),
    ("nous", "anthropic/claude-opus-5", true, true, "none minimal low medium high xhigh max+ultra"),
    ("nous", "stealth/space-bunny-alpha", true, nil, "none minimal low medium high xhigh max+ultra"),
    ("llamacpp", "Qwen3.6-35B-A3B-UD-Q4_K_M", true, nil, "none minimal low medium high xhigh max+ultra"),
    ("antigravity-agy", "gemini-3.8-flash-low", false, nil, ""),
  ]

  @Test func matchesWhatHermesSends() {
    for row in Self.recorded {
      let levels = ReasoningLevels(provider: row.provider, model: row.model, supportsReasoning: row.reasoning, canDisableReasoning: row.canDisable)
      let encoded = levels.levels.map { ([$0.effort] + $0.sameAs).joined(separator: "+") }.joined(separator: " ")
      #expect(encoded == row.levels, "\(row.provider) \(row.model)")
    }
  }

  /// The case that was wrong: Opus 5.5 has Extra high and Max, and no Off.
  @Test func opusFiveFiveHasExtraHighAndMaxButNoOff() {
    let levels = ReasoningLevels(provider: "anthropic", model: "claude-opus-5-5", supportsReasoning: true)
    #expect(levels.levels.map(\.label) == ["Low", "Medium", "High", "Extra high", "Max"])
    #expect(!levels.canTurnOff)
  }

  @Test func aConversationsEffortShowsAsTheLevelThatSendsIt() {
    let opus46 = ReasoningLevels(provider: "anthropic", model: "claude-opus-4-6", supportsReasoning: true)
    #expect(opus46.level(for: "xhigh")?.effort == "max")
    #expect(opus46.level(for: "ultra")?.effort == "max")
    #expect(opus46.level(for: "")?.effort == "medium")
    #expect(opus46.level(for: "none")?.label == "Off")
    let opus55 = ReasoningLevels(provider: "anthropic", model: "claude-opus-5-5", supportsReasoning: true)
    #expect(opus55.level(for: "none") == nil)
    #expect(opus55.level(for: "minimal")?.effort == "low")
  }

  @Test func modelsWithoutTheKnobOfferNothing() {
    #expect(ReasoningLevels(provider: "anthropic", model: "claude-haiku-4-5-20251001", supportsReasoning: true).isEmpty)
    #expect(ReasoningLevels(provider: "openai-codex", model: "gpt-6-sol", supportsReasoning: false).isEmpty)
    #expect(!ReasoningLevels(provider: "anthropic", model: "claude-haiku-5-5", supportsReasoning: true).isEmpty)
  }

  @Test func labels() {
    #expect(ReasoningLevels.label("xhigh") == "Extra high")
    #expect(ReasoningLevels.label("none") == "Off")
    #expect(ReasoningLevels.shortLabel("xhigh") == "X-High")
    #expect(ReasoningLevels.label("max") == "Max")
  }

  @Test func catalogCarriesTheDisableFlag() {
    let provider = ModelProvider(json: [
      "slug": "nous", "name": "Nous Portal", "authenticated": true, "models": ["anthropic/claude-fable-5.2"],
      "capabilities": ["anthropic/claude-fable-5.2": ["reasoning": true, "fast": false, "can_disable_reasoning": false]],
    ])
    let levels = provider.models[0].reasoningLevels(provider: provider.slug)
    #expect(!levels.canTurnOff)
    #expect(levels.levels.first?.effort == "minimal")
  }
}
