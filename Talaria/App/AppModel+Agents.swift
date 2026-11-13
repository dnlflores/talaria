import HermesKit
import SwiftUI

/// The agent hub's data: starred models, each bot's default model and catalog, its skills.
extension AppModel {
  /// The bot the iPhone hub shows: the one picked there, else the bot used last, else the default.
  var currentHubProfile: String {
    if !hubProfile.isEmpty, profile(named: hubProfile) != nil { return hubProfile }
    if !preferences.lastProfile.isEmpty, profile(named: preferences.lastProfile) != nil { return preferences.lastProfile }
    return orderedProfiles.first?.name ?? "default"
  }

  /// Bots in the order the hub and the bot list show them: the default first, then by name.
  var orderedProfiles: [Profile] {
    profiles.sorted { a, b in
      if a.isDefault != b.isDefault { return a.isDefault }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }

  /// A bot's page: the hub showing it (iPhone) or its row picked in the list (iPad).
  func showBotPage(_ profile: String) {
    hubProfile = profile
    areas.bot = profile
    hubPath = []
    tab = .bots
  }

  // MARK: Favourite models

  func isFavorite(provider: String, model: String) -> Bool {
    favoriteModels.contains(FavoriteModels.key(provider: provider, model: model))
  }

  /// Reads the stars from the Mac. Quiet on failure: the lists work without them.
  func loadFavorites(force: Bool = false) async {
    guard let client, force || !favoritesLoaded else { return }
    do {
      let values = try await client.uiPreferences()
      favoriteModels = FavoriteModels.decode(values[FavoriteModels.preferenceKey])
      favoritesLoaded = true
    } catch {
      // Older Hermes without the shared store: stars stay on this phone until it has one.
    }
  }

  /// Stars or unstars a model on the Mac, so the desktop app shows the same stars.
  func toggleFavorite(provider: String, model: String) {
    let before = favoriteModels
    let after = FavoriteModels.toggled(before, provider: provider, model: model)
    favoriteModels = after
    UISelectionFeedbackGenerator().selectionChanged()
    guard let client else { return }
    Task {
      do {
        // Merge with what the Mac has now, in case the desktop app starred something meanwhile.
        let current = FavoriteModels.decode(try await client.uiPreferences()[FavoriteModels.preferenceKey])
        let starred = !before.contains(FavoriteModels.key(provider: provider, model: model))
        let key = FavoriteModels.key(provider: provider, model: model)
        let merged = starred ? (current.contains(key) ? current : current + [key]) : current.filter { $0 != key }
        try await client.setUIPreferences([FavoriteModels.preferenceKey: FavoriteModels.encode(merged)])
        favoriteModels = merged
        favoritesLoaded = true
      } catch {
        favoriteModels = before
        show("Could not save the star: \(error.localizedDescription)", kind: .failure)
      }
    }
  }

  // MARK: A bot's default model

  /// Loads a bot's catalog as its default sees it. Kept per bot; `force` reads it again.
  func loadDefaultCatalog(_ profile: String, force: Bool = false) async {
    guard let client, force || defaultCatalogs[profile] == nil else { return }
    do {
      let catalog = try await client.modelCatalog(profile: profile)
      defaultCatalogs[profile] = catalog
      defaultCatalogErrors[profile] = nil
      // A plan check still running locks every Nous model: look again shortly, once.
      if catalog.providers.contains(where: \.isCheckingPlan), !force {
        try? await Task.sleep(for: .seconds(4))
        await loadDefaultCatalog(profile, force: true)
      }
    } catch {
      defaultCatalogErrors[profile] = error.localizedDescription
    }
  }

  /// The readable name of a provider slug, from any catalog already loaded.
  func providerName(_ slug: String) -> String {
    for catalog in defaultCatalogs.values {
      if let provider = catalog.providers.first(where: { $0.slug == slug }) { return provider.name }
    }
    return slug
  }

  /// Makes a model the bot's default for new chats. Returns the question to ask first when the
  /// model is expensive; nil when it was saved (or failed, with a toast).
  func setDefaultModel(profile: String, provider: String, model: String, confirmed: Bool = false) async -> String? {
    guard let client else { return nil }
    do {
      let result = try await client.setDefaultModel(profile: profile, provider: provider, model: model, confirmed: confirmed)
      if result.needsConfirmation {
        return result.confirmationMessage.isEmpty ? "This model costs more than most. Use it anyway?" : result.confirmationMessage
      }
      if var catalog = defaultCatalogs[profile] {
        catalog.model = result.model
        catalog.provider = result.provider
        defaultCatalogs[profile] = catalog
      }
      await refreshProfilesNow()
      let note = result.notice.isEmpty ? "" : " \(result.notice)"
      show("New chats with \(title(forProfile: profile)) use \(ModelName(result.model).display).\(note)", kind: .success)
      Task { await loadDefaultCatalog(profile, force: true) }
    } catch {
      show("Could not change the default model: \(error.localizedDescription)", kind: .failure)
    }
    return nil
  }

  // MARK: Skills

  func loadSkills(_ profile: String, force: Bool = false) async throws {
    guard let client, force || skillLists[profile] == nil else { return }
    skillLists[profile] = try await client.skills(profile: profile)
  }
}
