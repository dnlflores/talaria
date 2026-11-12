import Foundation
import Testing

@testable import HermesKit

@Suite struct ModelNamingTests {
  @Test func idsReadAsTheirNames() {
    #expect(ModelName("claude-opus-5-5").display == "Opus 5.5")
    #expect(ModelName("claude-opus-4-5-20251101").display == "Opus 4.5")
    #expect(ModelName("claude-opus-4-6-thinking").display == "Opus 4.6 Thinking")
    #expect(ModelName("claude-haiku-4-5-20251001").display == "Haiku 4.5")
    #expect(ModelName("gpt-6.1-sol").display == "GPT-6.1 Sol")
    #expect(ModelName("gpt-6.1-sol-900k").display == "GPT-6.1 Sol 900K")
    #expect(ModelName("gpt-oss-120b-medium").display == "GPT OSS 120B Medium")
    #expect(ModelName("gemini-3.8-flash-low").display == "Gemini 3.8 Flash Low")
    #expect(ModelName("anthropic/claude-opus-5.5").display == "Opus 5.5")
    #expect(ModelName("deepseek/deepseek-v4.1-flash").display == "DeepSeek V4.1 Flash")
    #expect(ModelName("x-ai/grok-4.7").display == "Grok 4.7")
    #expect(ModelName("Qwen3.6-35B-A3B-UD-Q4_K_M").display == "Qwen3.6 35B A3B Q4")
    #expect(ModelName("").display == "No model")
  }

  @Test func versionsAndLinesOfModels() {
    #expect(ModelName("claude-opus-4-5-20251101").version == [4, 5])
    #expect(ModelName("claude-opus-4-5-20251101").family == "Opus")
    #expect(ModelName("gpt-6.1-sol-900k").family == "GPT Sol")
    #expect(ModelName("gpt-oss-120b-medium").version == [])
    #expect(ModelName("Qwen3.6-35B-A3B-UD-Q4_K_M").version == [3, 6])
    #expect(ModelName("openai/gpt-5.5").vendor == "openai")
    #expect(ModelName.vendorTitle("x-ai") == "xAI")
  }

  private func provider(_ models: [String], unavailable: [String] = []) -> ModelProvider {
    ModelProvider(json: [
      "slug": "p", "name": "P", "authenticated": true,
      "models": .array(models.map { .string($0) }), "unavailable_models": .array(unavailable.map { .string($0) }),
    ])
  }

  /// The order the backend lists Anthropic's models in: oldest first, lines mixed.
  @Test func newestFirstWithEachLineTogether() {
    let anthropic = provider([
      "claude-opus-4-5-20251101", "claude-opus-4-6", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
      "claude-sonnet-4-6", "claude-sonnet-5-5", "claude-haiku-4-5-20251001", "claude-haiku-5-5",
      "claude-fable-5", "claude-fable-5-2",
    ])
    #expect(anthropic.sections.count == 1)
    #expect(anthropic.sections[0].title.isEmpty)
    #expect(anthropic.sections[0].models.map { ModelName($0.name).display } == [
      "Opus 5.5", "Opus 5", "Opus 4.8", "Opus 4.6", "Opus 4.5",
      "Sonnet 5.5", "Sonnet 4.6", "Haiku 5.5", "Haiku 4.5", "Fable 5.2", "Fable 5",
    ])
  }

  @Test func variantsFollowTheirModel() {
    let codex = provider(["gpt-6-sol-900k", "gpt-6.1-sol-900k", "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol"])
    #expect(codex.sections[0].models.map { ModelName($0.name).display } == [
      "GPT-6.1 Sol", "GPT-6.1 Sol 900K", "GPT-6 Sol", "GPT-6 Sol 900K", "GPT-6 Astra",
    ])
  }

  /// A free tier lists models it does not include; a router gets a heading per vendor.
  @Test func lockedModelsAndVendorHeadings() {
    let portal = provider(
      ["anthropic/claude-opus-5.5", "openai/gpt-6.1-sol", "deepseek/deepseek-v4.1-flash", "google/gemini-3.8-flash", "openai/gpt-5.4-mini"],
      unavailable: ["anthropic/claude-opus-5.5", "openai/gpt-6.1-sol"])
    #expect(portal.availableModels.count == 3)
    #expect(portal.lockedModels.map(\.name) == ["openai/gpt-6.1-sol", "anthropic/claude-opus-5.5"])
    #expect(portal.sections.map(\.title) == ["DeepSeek", "Google", "OpenAI"])
    #expect(portal.sections.last?.models.map(\.name) == ["openai/gpt-5.4-mini"])
    #expect(!portal.isAvailable(portal.models[0]))
    #expect(!portal.isCheckingPlan)
  }

  /// Before the backend has checked the plan it locks every model; that is not "none included".
  @Test func aPlanNotCheckedYetIsSaidSo() {
    let pending = ModelProvider(json: [
      "slug": "nous", "name": "Nous Portal", "authenticated": true, "free_tier_pending": true,
      "models": ["a/x", "b/y"], "unavailable_models": ["a/x", "b/y"], "warning": "Checking Nous plan entitlement…",
    ])
    #expect(pending.isCheckingPlan)
    #expect(pending.warning.hasPrefix("Checking"))
  }
}
