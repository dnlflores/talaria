import HermesKit
import SwiftUI

/// Model and thinking effort for this conversation only. The bot's own default is not changed.
///
/// The model in use sits at the top, so changing only the effort never needs the lists; starred
/// models come next, and every model is one tap away, a provider at a time.
struct ModelPickerSheet: View {
  let chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss
  @State private var path: [String] = []
  @State private var confirmation: (model: String, provider: String, message: String)?
  @State private var isSwitching = false

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          CurrentModelCard(
            model: chat.info.model, providerSlug: currentSlug, providerName: choices.currentProviderName
          ) { path.append("all") }
          let levels = reasoningLevels
          if !levels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              GroupedSection("Thinking effort") {
                EffortPicker(levels: levels, selection: chat.info.reasoningEffort) { effort in
                  Task { await chat.setEffort(effort) }
                }
                .padding(5)
              }
              if !levels.canTurnOff {
                Text("This model always thinks, so it has no Off.")
                  .font(AppFont.caption)
                  .foregroundStyle(palette.foregroundMuted)
                  .padding(.horizontal, 18)
              }
            }
          }
          FavouritesBlock(choices: choices, openAll: { path.append("all") }) { model, provider in
            choose(model, provider: provider, confirmed: false)
          }
          if let error = chat.catalogError, chat.catalog == nil {
            Label("Could not load models: \(error)", systemImage: "exclamationmark.triangle")
              .font(AppFont.footnote)
              .foregroundStyle(palette.dangerForeground)
              .padding(.horizontal, 6)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .screenBackground()
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(for: String.self) { _ in
        AllModelsPage(title: "All models", choices: { choices }) { model, provider in
          choose(model, provider: provider, confirmed: false)
        }
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
          }
        }
      }
    }
    .task { await chat.loadCatalog() }
    .task { await app.loadFavorites(force: true) }
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

  // MARK: Rules

  private var choices: ModelChoices {
    ModelChoices(
      catalog: chat.catalog, error: chat.catalogError, model: chat.info.model, provider: chat.info.provider,
      isSwitching: isSwitching)
  }

  private var currentSlug: String { choices.currentProvider?.slug ?? chat.info.provider }

  /// The efforts the model in use offers. Before the catalog loads (or for a model it does not
  /// list) Hermes's rules for the model's name apply.
  private var reasoningLevels: ReasoningLevels {
    let provider = choices.currentProvider
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
            .frame(height: 38)
            .background(isOn ? palette.selectionFill : Color.clear, in: Capsule())
            .overlay {
              if isOn { Capsule().strokeBorder(palette.selectionStroke, lineWidth: 1.5) }
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
