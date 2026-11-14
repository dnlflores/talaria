import HermesKit
import SwiftUI

// The model chooser's parts, shared by a chat's Model sheet and a bot's Default Model page: the
// model in use as a card, the starred models, and every model behind provider chips.

/// What a model chooser shows: the catalog and the model in use.
struct ModelChoices {
  var catalog: [ModelProvider]?
  var error: String?
  var model: String
  /// The provider slug in use. Empty: whichever provider the catalog marks current.
  var provider: String
  var isSwitching = false

  func isCurrentProvider(_ candidate: ModelProvider) -> Bool {
    provider.isEmpty ? candidate.isCurrent : candidate.slug == provider
  }

  func isCurrent(_ model: ModelProvider.Model, in candidate: ModelProvider) -> Bool {
    model.name == self.model && isCurrentProvider(candidate)
  }

  var currentProvider: ModelProvider? { catalog?.first(where: isCurrentProvider) }
  var currentProviderName: String { currentProvider?.name ?? provider }

  /// The providers worth a chip: the ones signed in on the Mac.
  var usableProviders: [ModelProvider] { (catalog ?? []).filter(\.isAuthenticated) }

  /// One starred model, matched against the catalog when it is in there.
  struct Favourite: Identifiable {
    var id: String { key }
    let key: String
    let slug: String
    let modelID: String
    let provider: ModelProvider?
    let model: ModelProvider.Model?

    var isUsable: Bool {
      guard let provider, let model else { return false }
      return provider.isAuthenticated && provider.isAvailable(model) && !provider.isCheckingPlan
    }
  }

  func favourites(_ keys: [String]) -> [Favourite] {
    keys.compactMap { key in
      guard let parts = FavoriteModels.parts(key) else { return nil }
      let provider = catalog?.first { $0.slug == parts.provider }
      let model = provider?.models.first { $0.name == parts.model }
      return Favourite(key: key, slug: parts.provider, modelID: parts.model, provider: provider, model: model)
    }
  }
}

/// The model in use on a lavender card. Tapping it opens every model.
struct CurrentModelCard: View {
  let model: String
  let providerSlug: String
  let providerName: String
  var placeholder = "Bot default"
  var action: (() -> Void)?
  @Environment(\.palette) private var palette

  var body: some View {
    let name = ModelName(model)
    let card = HStack(spacing: 14) {
      ModelLogo(model: model, provider: providerSlug, providerName: providerName, size: 32)
        .frame(width: 38, height: 38)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.isEmpty ? placeholder : name.display)
          .font(AppFont.sans(18, .bold))
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
        Text(providerName.isEmpty ? " " : providerName)
          .font(AppFont.sans(14))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if action != nil {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.chevron)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassCard(radius: 24, fill: palette.currentFill, stroke: palette.currentStroke)
    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

    Group {
      if let action {
        Button(action: action) { card }.buttonStyle(.plain)
      } else {
        card
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("In use: \(model.isEmpty ? placeholder : name.display), \(providerName)")
    .accessibilityHint(action == nil ? "" : "Shows every model")
    .accessibilityIdentifier("model.current")
  }
}

/// "FAVOURITES" with an "All models" link, and the starred models on a card.
struct FavouritesBlock: View {
  let choices: ModelChoices
  let openAll: () -> Void
  let choose: (_ model: String, _ provider: String) -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    let favourites = choices.favourites(app.favoriteModels)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        GroupHeading(text: "Favourites")
        Spacer(minLength: 8)
        Button(action: openAll) {
          Text("All models")
            .font(AppFont.sans(15, .bold))
            .foregroundStyle(palette.primaryText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("model.all")
      }
      .padding(.horizontal, 6)

      if favourites.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "star")
            .font(.system(size: 17))
            .foregroundStyle(palette.iconMuted)
          Text("Star models in All models to keep them here. Stars are shared with Hermes on your Mac.")
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
      } else {
        VStack(spacing: 0) {
          ForEach(Array(favourites.enumerated()), id: \.element.id) { offset, favourite in
            if offset > 0 { GroupDivider(inset: 18 + 34 + 14) }
            ModelRow(
              modelID: favourite.modelID, providerSlug: favourite.slug,
              providerName: favourite.provider?.name ?? favourite.slug,
              subtitle: favourite.provider?.name ?? favourite.slug,
              isCurrent: favourite.provider.map { p in favourite.model.map { choices.isCurrent($0, in: p) } ?? false } ?? false,
              isEnabled: favourite.isUsable && !choices.isSwitching,
              horizontalPadding: 18, subtitleIsID: false
            ) {
              choose(favourite.modelID, favourite.slug)
            }
          }
        }
        .glassCard()
      }
    }
  }
}

/// A model as people say it, under it its id (or its provider), a check when it is in use, and
/// its star.
struct ModelRow: View {
  let modelID: String
  let providerSlug: String
  let providerName: String
  let subtitle: String
  let isCurrent: Bool
  let isEnabled: Bool
  var horizontalPadding: CGFloat = 0
  /// Ids keep their end (`…-900k`); a provider's name reads from its start.
  var subtitleIsID = true
  let choose: () -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    let name = ModelName(modelID)
    let isFavorite = app.isFavorite(provider: providerSlug, model: modelID)
    HStack(spacing: 6) {
      Button(action: choose) {
        HStack(spacing: 14) {
          ModelLogo(model: modelID, provider: providerSlug, providerName: providerName, size: 30)
            .frame(width: 34, height: 34)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(name.name)
                .font(AppFont.sans(17))
                .foregroundStyle(isEnabled || isCurrent ? palette.foreground : palette.foregroundMuted)
                .lineLimit(1)
              ForEach(name.tags, id: \.self) { TagLabel(text: $0) }
            }
            Text(subtitle)
              .font(AppFont.sans(14))
              .foregroundStyle(palette.foregroundMuted)
              .lineLimit(1)
              .truncationMode(subtitleIsID ? .middle : .tail)
          }
          Spacer(minLength: 8)
          if isCurrent {
            Image(systemName: "checkmark")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(palette.primaryText)
          }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(name.display + ", \(providerName)" + (isCurrent ? ", in use" : ""))
      .accessibilityIdentifier("model.row")

      Button {
        app.toggleFavorite(provider: providerSlug, model: modelID)
      } label: {
        Image(systemName: isFavorite ? "star.fill" : "star")
          .font(.system(size: 20, weight: .regular))
          .foregroundStyle(isFavorite ? palette.star : palette.iconSubtle)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isFavorite ? "Remove \(name.display) from favourites" : "Add \(name.display) to favourites")
      .accessibilityIdentifier("model.star")
    }
    .padding(.leading, horizontalPadding)
    .padding(.trailing, max(horizontalPadding - 10, 0))
  }
}

/// Every model: a search field, a chip per provider (the one in use picked first), and the
/// chosen provider's models newest first, the ones the plan lacks folded away at the end.
struct AllModelsPage: View {
  let title: String
  let choices: () -> ModelChoices
  let choose: (_ model: String, _ provider: String) -> Void
  @Environment(\.palette) private var palette
  @State private var query = ""
  @State private var selected: String?
  @State private var showsLocked = false

  var body: some View {
    let choices = choices()
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GlassSearchField(prompt: "Search all models", text: $query)
          .padding(.horizontal, 16)
        if !choices.usableProviders.isEmpty {
          chips(choices)
        }
        content(choices)
      }
      .padding(.top, 6)
      .padding(.bottom, 28)
    }
    .scrollDismissesKeyboard(.immediately)
    .screenBackground()
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { pickDefault(choices) }
    .onChange(of: choices.usableProviders.map(\.slug)) { _, _ in pickDefault(choices) }
  }

  private func pickDefault(_ choices: ModelChoices) {
    let slugs = choices.usableProviders.map(\.slug)
    if let selected, slugs.contains(selected) { return }
    selected = choices.currentProvider.flatMap { $0.isAuthenticated ? $0.slug : nil } ?? slugs.first
  }

  private func chips(_ choices: ModelChoices) -> some View {
    ScrollViewReader { reader in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(choices.usableProviders) { provider in
            let inUse = choices.isCurrentProvider(provider)
            Chip(
              title: provider.name, count: provider.availableModels.count,
              isSelected: query.isEmpty && selected == provider.slug, marksCurrent: inUse
            ) {
              withAnimation(.snappy(duration: 0.25)) {
                query = ""
                selected = provider.slug
                showsLocked = false
              }
            }
            .id(provider.slug)
            .accessibilityLabel(
              "\(provider.name), \(provider.availableModels.count) models" + (inUse ? ", In use" : ""))
            .accessibilityIdentifier("model.provider")
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
      }
      .onAppear { if let selected { reader.scrollTo(selected, anchor: .center) } }
      .onChange(of: selected) { _, slug in
        if let slug { withAnimation { reader.scrollTo(slug, anchor: .center) } }
      }
    }
  }

  @ViewBuilder
  private func content(_ choices: ModelChoices) -> some View {
    if let catalog = choices.catalog {
      let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
      if !needle.isEmpty {
        let found = catalog.filter(\.isAuthenticated).flatMap { provider in
          ModelProvider.ordered(provider.availableModels).filter { model in
            model.name.lowercased().contains(needle) || ModelName(model.name).display.lowercased().contains(needle)
              || provider.name.lowercased().contains(needle)
          }.map { (provider, $0) }
        }
        GroupHeading(text: "Results").padding(.horizontal, 22)
        if found.isEmpty {
          note("No model matches.")
        } else {
          rows(found.map { ($0.0, $0.1, true) }, choices: choices, showsProvider: true)
        }
      } else if let provider = catalog.first(where: { $0.slug == selected }) {
        providerModels(provider, choices: choices)
      }
    } else if let error = choices.error {
      Label("Could not load models: \(error)", systemImage: "exclamationmark.triangle")
        .font(AppFont.footnote)
        .foregroundStyle(palette.dangerForeground)
        .padding(.horizontal, 22)
    } else {
      HStack(spacing: 10) {
        ProgressView()
        Text("Loading models").font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 24)
    }
  }

  @ViewBuilder
  private func providerModels(_ provider: ModelProvider, choices: ModelChoices) -> some View {
    if provider.isCheckingPlan {
      Label("Checking which models your plan includes. They unlock in a moment.", systemImage: "hourglass")
        .font(AppFont.label)
        .foregroundStyle(palette.foregroundMuted)
        .padding(.horizontal, 22)
    }
    let sections = provider.sections
    if sections.isEmpty, !provider.isCheckingPlan {
      note("This plan includes no models from \(provider.name).")
    }
    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
      GroupHeading(text: section.title.isEmpty ? "All models" : section.title)
        .padding(.horizontal, 22)
        .padding(.top, index == 0 ? 0 : 10)
      rows(section.models.map { (provider, $0, true) }, choices: choices, showsProvider: false)
    }
    if !provider.lockedModels.isEmpty, !provider.isCheckingPlan {
      Button {
        withAnimation(.snappy(duration: 0.25)) { showsLocked.toggle() }
      } label: {
        HStack(spacing: 6) {
          GroupHeading(text: "\(provider.lockedModels.count) more need an upgrade")
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.chevron)
            .rotationEffect(.degrees(showsLocked ? 180 : 0))
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if showsLocked {
        rows(provider.lockedModels.map { (provider, $0, false) }, choices: choices, showsProvider: false)
      }
    }
  }

  private func rows(
    _ entries: [(ModelProvider, ModelProvider.Model, Bool)], choices: ModelChoices, showsProvider: Bool
  ) -> some View {
    LazyVStack(spacing: 0) {
      ForEach(Array(entries.enumerated()), id: \.offset) { offset, entry in
        let (provider, model, usable) = entry
        if offset > 0 { GroupDivider(inset: 34 + 14) }
        ModelRow(
          modelID: model.name, providerSlug: provider.slug, providerName: provider.name,
          subtitle: showsProvider ? "\(provider.name) · \(model.name)" : model.name,
          isCurrent: choices.isCurrent(model, in: provider),
          isEnabled: usable && !choices.isSwitching
        ) {
          choose(model.name, provider.slug)
        }
      }
    }
    .padding(.horizontal, 22)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(AppFont.footnote)
      .foregroundStyle(palette.foregroundMuted)
      .frame(maxWidth: .infinity)
      .padding(.top, 20)
  }
}
