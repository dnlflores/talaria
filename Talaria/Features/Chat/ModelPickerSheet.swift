import HermesKit
import SwiftUI

/// Model and thinking effort for this conversation only. The bot's own default is not changed.
struct ModelPickerSheet: View {
  let chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var confirmation: (model: String, provider: String, message: String)?
  @State private var isSwitching = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Thinking effort")
            EffortPicker(selection: chat.info.reasoningEffort) { effort in
              Task { await chat.setEffort(effort) }
            }
          }

          if let providers = chat.catalog {
            let visible = providers.compactMap { provider -> (ModelProvider, [ModelProvider.Model])? in
              let models = provider.models.filter { matches($0.name, provider: provider.name) }
              return models.isEmpty ? nil : (provider, models)
            }
            if visible.isEmpty {
              Text("No model matches.").font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
            }
            ForEach(visible, id: \.0.id) { provider, models in
              VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                  sectionTitle(provider.name)
                  if !provider.isAuthenticated { TagLabel(text: "Not signed in") }
                }
                VStack(spacing: 0) {
                  ForEach(Array(models.enumerated()), id: \.element.id) { offset, model in
                    if offset > 0 { Hairline().padding(.leading, 16) }
                    modelRow(model, provider: provider)
                  }
                }
                .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
              }
            }
          } else if let error = chat.catalogError {
            Label("Could not load models: \(error)", systemImage: "exclamationmark.triangle")
              .font(AppFont.footnote)
              .foregroundStyle(palette.dangerForeground)
          } else {
            HStack(spacing: 10) {
              ProgressView()
              Text("Loading models").font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .background(palette.sheetSolid)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
      .navigationTitle("Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
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
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
      .font(AppFont.sans(11, .semibold))
      .kerning(0.6)
      .foregroundStyle(palette.foregroundMuted)
      .padding(.leading, 4)
  }

  private func matches(_ model: String, provider: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    return needle.isEmpty || model.lowercased().contains(needle) || provider.lowercased().contains(needle)
  }

  private func modelRow(_ model: ModelProvider.Model, provider: ModelProvider) -> some View {
    let isCurrent = model.name == chat.info.model && (chat.info.provider.isEmpty || chat.info.provider == provider.slug)
    return Button {
      choose(model.name, provider: provider.slug, confirmed: false)
    } label: {
      HStack(spacing: 10) {
        Text(model.name)
          .font(AppFont.mono(13))
          .foregroundStyle(provider.isAuthenticated ? palette.foreground : palette.foregroundMuted)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        if model.supportsReasoning { TagLabel(text: "Thinking") }
        if model.supportsFast { TagLabel(text: "Fast") }
        if isCurrent {
          Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(palette.primaryText)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
    .disabled(!provider.isAuthenticated || isSwitching)
    .accessibilityIdentifier("model.row")
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

private struct EffortPicker: View {
  let selection: String
  let choose: (String) -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      ForEach(reasoningEfforts, id: \.self) { effort in
        let isOn = effort == selection
        Button {
          UISelectionFeedbackGenerator().selectionChanged()
          choose(effort)
        } label: {
          Text(label(effort))
            .font(AppFont.sans(13, isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? palette.foreground : palette.foregroundMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(isOn ? palette.card : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
              if isOn { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(effort)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
    .padding(4)
    .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func label(_ effort: String) -> String {
    switch effort {
    case "minimal": return "Min"
    case "medium": return "Med"
    case "xhigh": return "Max"
    default: return effort.capitalized
    }
  }
}
