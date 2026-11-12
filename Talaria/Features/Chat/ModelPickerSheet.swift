import HermesKit
import SwiftUI

/// Model and thinking effort for this conversation only. The bot's own default is not changed.
///
/// Two steps: pick a provider, then one of its models. The model in use sits at the top, so
/// changing only the effort never needs the lists.
struct ModelPickerSheet: View {
  let chat: ChatModel
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss
  @State private var path: [String] = []
  @State private var query = ""
  @State private var confirmation: (model: String, provider: String, message: String)?
  @State private var isSwitching = false

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if query.isEmpty {
            current
            let levels = reasoningLevels
            if !levels.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                GroupedSection("Thinking effort") {
                  EffortPicker(levels: levels, selection: chat.info.reasoningEffort) { effort in
                    Task { await chat.setEffort(effort) }
                  }
                  .padding(4)
                }
                if !levels.canTurnOff {
                  Text("This model always thinks, so it has no Off.")
                    .font(AppFont.caption)
                    .foregroundStyle(palette.foregroundMuted)
                    .padding(.horizontal, 4)
                }
              }
            }
            providers
          } else {
            searchResults
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .background(palette.sheetSolid.ignoresSafeArea())
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all models")
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(for: String.self) { slug in
        if let provider = chat.catalog?.first(where: { $0.slug == slug }) {
          ProviderModelsPage(provider: provider, chat: chat, isSwitching: isSwitching, close: { dismiss() }) { model in
            choose(model, provider: slug, confirmed: false)
          }
        }
      }
    }
    .task { await chat.loadCatalog() }
    .alert("Expensive model", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
      Button("Cancel", role: .cancel) { confirmation = nil }
      Button("Use it") {
        if let pending = confirmation { choose(pending.model, provider: pending.provider, confirmed: true) }
        confirmation = nil
      }
    } message: {
      Text(confirmation?.message ?? "")
    }
  }

  // MARK: Parts

  /// The model in use, named as people say it, with where it comes from.
  private var current: some View {
    let name = ModelName(chat.info.model)
    return HStack(spacing: 12) {
      Image(systemName: "cpu")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(palette.primaryText)
        .frame(width: 40, height: 40)
        .background(palette.subtle, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(chat.info.model.isEmpty ? "Bot default" : name.display)
          .font(AppFont.sans(17, .semibold))
          .foregroundStyle(palette.foreground)
        Text(currentProviderName)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("In use: \(name.display), \(currentProviderName)")
    .accessibilityIdentifier("model.current")
  }

  @ViewBuilder
  private var providers: some View {
    if let catalog = chat.catalog {
      GroupedSection("Choose a provider") {
        ForEach(Array(catalog.enumerated()), id: \.element.id) { offset, provider in
          if offset > 0 { GroupDivider() }
          providerRow(provider)
        }
      }
    } else if let error = chat.catalogError {
      Label("Could not load models: \(error)", systemImage: "exclamationmark.triangle")
        .font(AppFont.footnote)
        .foregroundStyle(palette.dangerForeground)
    } else {
      HStack(spacing: 10) {
        ProgressView()
        Text("Loading providers").font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
    }
  }

  private func providerRow(_ provider: ModelProvider) -> some View {
    let inUse = isCurrentProvider(provider)
    return Button {
      path.append(provider.slug)
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(provider.name)
            .font(AppFont.bodyMedium)
            .foregroundStyle(provider.isAuthenticated ? palette.foreground : palette.foregroundMuted)
            .lineLimit(1)
          Text(providerDetail(provider, inUse: inUse))
            .font(AppFont.footnote)
            .foregroundStyle(inUse ? palette.primaryText : palette.foregroundMuted)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if inUse { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(palette.primaryText) }
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.chevron)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
    .disabled(!provider.isAuthenticated)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(provider.name), \(providerDetail(provider, inUse: inUse))")
    .accessibilityIdentifier("model.provider")
  }

  private func providerDetail(_ provider: ModelProvider, inUse: Bool) -> String {
    if !provider.isAuthenticated { return "Not signed in on your Mac" }
    if inUse, !chat.info.model.isEmpty { return "In use: \(ModelName(chat.info.model).display)" }
    if provider.isCheckingPlan { return "Checking your plan…" }
    let count = provider.availableModels.count
    var text = count == 1 ? "1 model" : "\(count) models"
    if !provider.lockedModels.isEmpty { text += " · \(provider.lockedModels.count) more with an upgrade" }
    return text
  }

  /// Every model this plan can use whose name, id or provider matches.
  @ViewBuilder
  private var searchResults: some View {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    let found = (chat.catalog ?? []).filter(\.isAuthenticated).flatMap { provider in
      ModelProvider.ordered(provider.availableModels).filter { model in
        model.name.lowercased().contains(needle) || ModelName(model.name).display.lowercased().contains(needle)
          || provider.name.lowercased().contains(needle)
      }.map { (provider, $0) }
    }
    if found.isEmpty {
      Text(chat.catalog == nil ? "Loading models" : "No model matches.")
        .font(AppFont.footnote)
        .foregroundStyle(palette.foregroundMuted)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    } else {
      GroupedSection("") {
        ForEach(Array(found.enumerated()), id: \.offset) { offset, entry in
          if offset > 0 { GroupDivider() }
          ModelChoiceRow(
            model: entry.1, providerName: entry.0.name, isCurrent: isCurrent(entry.1, in: entry.0), isEnabled: !isSwitching
          ) {
            choose(entry.1.name, provider: entry.0.slug, confirmed: false)
          }
        }
      }
    }
  }

  // MARK: Rules

  private var currentProviderName: String {
    if let provider = chat.catalog?.first(where: isCurrentProvider) { return provider.name }
    return chat.info.provider
  }

  private func isCurrentProvider(_ provider: ModelProvider) -> Bool {
    chat.info.provider.isEmpty ? provider.isCurrent : provider.slug == chat.info.provider
  }

  private func isCurrent(_ model: ModelProvider.Model, in provider: ModelProvider) -> Bool {
    model.name == chat.info.model && isCurrentProvider(provider)
  }

  /// The efforts the model in use offers. Before the catalog loads (or for a model it does not
  /// list) Hermes's rules for the model's name apply.
  private var reasoningLevels: ReasoningLevels {
    let provider = chat.catalog?.first(where: isCurrentProvider)
    let slug = provider?.slug ?? chat.info.provider
    if let model = provider?.models.first(where: { $0.name == chat.info.model }) {
      return model.reasoningLevels(provider: slug)
    }
    return ReasoningLevels(provider: slug, model: chat.info.model, supportsReasoning: true)
  }

  private func choose(_ model: String, provider: String, confirmed: Bool) {
    isSwitching = true
    Task {
      let prompt = await chat.setModel(model, provider: provider, confirmed: confirmed)
      isSwitching = false
      if let prompt {
        confirmation = (model, provider, prompt)
      } else {
        dismiss()
      }
    }
  }
}

/// One provider's models: the ones this plan includes, newest first, and the rest folded away.
private struct ProviderModelsPage: View {
  let provider: ModelProvider
  let chat: ChatModel
  let isSwitching: Bool
  let close: () -> Void
  let choose: (String) -> Void
  @Environment(\.palette) private var palette
  @State private var showsLocked = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if provider.isCheckingPlan {
          Label("Checking which models your plan includes. They unlock in a moment.", systemImage: "hourglass")
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundMuted)
            .padding(.horizontal, 4)
        }
        ForEach(provider.sections) { section in
          GroupedSection(section.title) {
            ForEach(Array(section.models.enumerated()), id: \.element.id) { offset, model in
              if offset > 0 { GroupDivider() }
              ModelChoiceRow(model: model, providerName: nil, isCurrent: isCurrent(model), isEnabled: !isSwitching) {
                choose(model.name)
              }
            }
          }
        }
        if provider.sections.isEmpty, !provider.isCheckingPlan {
          Text("This plan includes no models from \(provider.name).")
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundMuted)
        }
        if !provider.lockedModels.isEmpty, !provider.isCheckingPlan { locked }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(palette.sheetSolid.ignoresSafeArea())
    .navigationTitle(provider.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done", action: close)
      }
    }
  }

  private var locked: some View {
    VStack(alignment: .leading, spacing: 8) {
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
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if showsLocked {
        VStack(spacing: 0) {
          ForEach(Array(provider.lockedModels.enumerated()), id: \.element.id) { offset, model in
            if offset > 0 { GroupDivider() }
            ModelChoiceRow(model: model, providerName: nil, isCurrent: false, isEnabled: false) {}
          }
        }
        .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
      }
    }
  }

  private func isCurrent(_ model: ModelProvider.Model) -> Bool {
    guard model.name == chat.info.model else { return false }
    return chat.info.provider.isEmpty ? provider.isCurrent : provider.slug == chat.info.provider
  }
}

/// A model as people say it, its variant tags, and its id in small type for the curious.
private struct ModelChoiceRow: View {
  let model: ModelProvider.Model
  /// Shown in search results, where models from every provider mix.
  let providerName: String?
  let isCurrent: Bool
  let isEnabled: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    let name = ModelName(model.name)
    Button(action: action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(name.name)
              .font(AppFont.body)
              .foregroundStyle(isEnabled || isCurrent ? palette.foreground : palette.foregroundMuted)
            ForEach(name.tags, id: \.self) { TagLabel(text: $0) }
          }
          Text(providerName.map { "\($0) · \(model.name)" } ?? model.name)
            .font(AppFont.mono(11))
            .foregroundStyle(palette.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 8)
        if isCurrent {
          Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(palette.primaryText)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
    .disabled(!isEnabled)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(name.display + (providerName.map { ", \($0)" } ?? "") + (isCurrent ? ", in use" : ""))
    .accessibilityIdentifier("model.row")
  }
}

/// The model's efforts as one row of segments: full names when they fit, short ones otherwise.
private struct EffortPicker: View {
  let levels: ReasoningLevels
  let selection: String
  let choose: (String) -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    let selected = levels.level(for: selection)?.effort
    ViewThatFits(in: .horizontal) {
      row(selected: selected, short: false)
      row(selected: selected, short: true)
    }
  }

  private func row(selected: String?, short: Bool) -> some View {
    HStack(spacing: 4) {
      ForEach(levels.levels) { level in
        let isOn = level.effort == selected
        Button {
          UISelectionFeedbackGenerator().selectionChanged()
          choose(level.effort)
        } label: {
          Text(short ? level.shortLabel : level.label)
            .font(AppFont.sans(13, isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? palette.foreground : palette.foregroundMuted)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(isOn ? palette.card : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
              if isOn { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level.label)
        .accessibilityIdentifier("effort.\(level.effort)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
  }
}
