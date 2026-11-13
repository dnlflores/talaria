import Foundation
import Testing

@testable import HermesKit

@Suite struct AgentSettingsTests {
  @Test func favouritesUseTheDesktopAppsKeys() {
    #expect(FavoriteModels.preferenceKey == "hermes.desktop.favorite-models")
    #expect(FavoriteModels.key(provider: "openai-codex", model: "gpt-6.1-sol") == "openai-codex::gpt-6.1-sol")
    let parts = FavoriteModels.parts("nous::anthropic/claude-opus-5.5")
    #expect(parts?.provider == "nous")
    #expect(parts?.model == "anthropic/claude-opus-5.5")
    #expect(FavoriteModels.parts("no-separator") == nil)
    #expect(FavoriteModels.parts("::model") == nil)
  }

  @Test func favouritesRoundTripInOrder() {
    let raw = #"["anthropic::claude-opus-5-5","nous::anthropic/claude-sonnet-5","anthropic::claude-opus-5-5",""]"#
    let keys = FavoriteModels.decode(raw)
    #expect(keys == ["anthropic::claude-opus-5-5", "nous::anthropic/claude-sonnet-5"])
    // Slashes stay as they are, the way the desktop app's JSON.stringify writes them.
    #expect(FavoriteModels.encode(keys) == #"["anthropic::claude-opus-5-5","nous::anthropic/claude-sonnet-5"]"#)
    #expect(FavoriteModels.encode([]) == nil)
    #expect(FavoriteModels.decode(nil).isEmpty)
    #expect(FavoriteModels.decode("not json").isEmpty)
    #expect(FavoriteModels.decode(#"{"a":1}"#).isEmpty)
  }

  @Test func starringAppendsAndUnstarringRemoves() {
    var keys = ["a::one"]
    keys = FavoriteModels.toggled(keys, provider: "b", model: "two")
    #expect(keys == ["a::one", "b::two"])
    keys = FavoriteModels.toggled(keys, provider: "a", model: "one")
    #expect(keys == ["b::two"])
  }

  @Test func defaultCatalogCarriesTheBotsDefault() throws {
    let json = try JSONValue.parse(Data(#"""
      {"model": "claude-opus-5-5", "provider": "anthropic",
       "providers": [
         {"slug": "openai-codex", "name": "ChatGPT or Codex Subscription", "is_current": false, "authenticated": true, "models": ["gpt-6.1-sol"]},
         {"slug": "anthropic", "name": "Anthropic", "is_current": true, "authenticated": true, "models": ["claude-opus-5-5"]}
       ]}
      """#.utf8))
    let catalog = ModelCatalog(json: json)
    #expect(catalog.model == "claude-opus-5-5")
    #expect(catalog.provider == "anthropic")
    #expect(catalog.providers.first?.slug == "anthropic")
    #expect(catalog.providers.count == 2)
  }

  @Test func savingAnExpensiveDefaultAsksFirst() throws {
    let ask = DefaultModelResult(
      json: try JSONValue.parse(Data(#"{"ok": false, "confirm_required": true, "confirm_message": "Costs a lot"}"#.utf8)),
      provider: "anthropic", model: "claude-opus-5-5")
    #expect(ask.needsConfirmation)
    #expect(ask.confirmationMessage == "Costs a lot")
    let saved = DefaultModelResult(
      json: try JSONValue.parse(Data(#"{"ok": true, "provider": "anthropic", "model": "claude-opus-5-5"}"#.utf8)),
      provider: "x", model: "y")
    #expect(!saved.needsConfirmation)
    #expect(saved.provider == "anthropic")
    #expect(saved.model == "claude-opus-5-5")
  }

  @Test func skillsListByCategory() throws {
    let json = try JSONValue.parse(Data(#"""
      {"skills": {"productivity": ["xlsx", "docx"], "autonomous-ai-agents": ["codex"], "": ["loose"], "empty": []}}
      """#.utf8))
    let list = SkillCategory.list(from: json)
    #expect(list.map(\.name) == ["autonomous-ai-agents", "productivity", ""])
    #expect(list[1].skills == ["docx", "xlsx"])
    #expect(list[0].title == "Autonomous AI agents")
    #expect(list[2].title == "Other")
  }
}
