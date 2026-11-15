import HermesKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer as a card: the text on top, and under it attach, the model in use (tap to change
/// it), dictation and send.
struct ComposerView: View {
  @Bindable var chat: ChatModel
  /// Opens the model and effort chooser.
  var openModels: () -> Void = {}
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var showsPhotos = false
  @State private var showsFiles = false
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var dictation = Dictation()
  /// The text before dictation started; what is heard goes after it.
  @State private var dictationBase = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if chat.hasQueue {
        QueuePanel(chat: chat)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      if !chat.attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(chat.attachments) { attachment in
              AttachmentChipView(attachment: attachment) { chat.removeAttachment(attachment.id) }
            }
          }
          .padding(.horizontal, 4)
        }
      }
      if !statusLine.isEmpty {
        Text(statusLine)
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundMuted)
          .padding(.horizontal, 8)
      }

      VStack(alignment: .leading, spacing: 8) {
        ComposerInput(text: $chat.draft, placeholder: placeholder) {
          // Return on a hardware keyboard; Shift-Return adds a line (ComposerInput).
          if chat.canSend { send() }
        }
        .overlay(alignment: .topLeading) {
          if chat.draft.isEmpty {
            Text(dictation.state == .listening ? "Listening…" : placeholder)
              .font(AppFont.sans(17))
              .foregroundStyle(palette.placeholder)
              .lineLimit(1)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 8)
        .padding(.top, 6)

        HStack(spacing: 4) {
          attachMenu
          modelButton
          Spacer(minLength: 0)
          micButton
          sendButton
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 12)
      .padding(.bottom, 10)
      .glassCard(radius: 30, fill: palette.card)
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.25), value: chat.queue.entries.map(\.id.uuidString) + chat.macQueue.map(\.id))
    .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      photoItems = []
      for (offset, item) in items.enumerated() {
        Task {
          if let data = try? await item.loadTransferable(type: Data.self) {
            chat.addImage(data: data, name: "photo-\(offset + 1).jpg")
          } else {
            app.show("Could not load that photo.", kind: .failure)
          }
        }
      }
    }
    .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      for url in urls { importFile(url) }
    }
    .onDisappear { dictation.stop() }
  }

  private var placeholder: String {
    if chat.continuesAsNewVersion { return "Continue in a new version" }
    if chat.sendQueues { return "Queue a follow-up" }
    return "Ask \(app.title(forProfile: chat.profile))"
  }

  private var statusLine: String {
    if !chat.uploadStatus.isEmpty { return chat.uploadStatus }
    if chat.isBranching { return "Starting a new version" }
    return ""
  }

  private func send() {
    dictation.stop()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { await chat.send() }
  }

  private var attachMenu: some View {
    Menu {
      Button {
        showsPhotos = true
      } label: {
        Label("Photo Library", systemImage: "photo.on.rectangle")
      }
      Button {
        showsFiles = true
      } label: {
        Label("Files", systemImage: "folder")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(palette.icon)
        .frame(width: 42, height: 42)
        .background(palette.card, in: Circle())
        .overlay { Circle().strokeBorder(palette.border, lineWidth: 1) }
        .contentShape(Circle())
    }
    .accessibilityLabel("Attach")
  }

  // MARK: Model

  /// "GPT-6.1 Sol 900K • High": the model this chat uses and its thinking effort. `short` names
  /// the effort briefly (Extra high is "X-High"), for when the full line does not fit.
  private func modelLine(short: Bool = false) -> String {
    let model = chat.info.model.isEmpty ? (app.profile(named: chat.profile)?.model ?? "") : chat.info.model
    guard !model.isEmpty else { return "Model" }
    var line = Format.modelName(model)
    let effort = chat.info.reasoningEffort
    if !effort.isEmpty, effort != "none" {
      let levels = ReasoningLevels(provider: chat.info.provider, model: model, supportsReasoning: true)
      let level = levels.level(for: effort)
      line += " • " + ((short ? level?.shortLabel : level?.label) ?? ReasoningLevels.label(effort))
    }
    return line
  }

  private var modelButton: some View {
    let model = chat.info.model.isEmpty ? (app.profile(named: chat.profile)?.model ?? "") : chat.info.model
    let provider = chat.info.provider.isEmpty ? (app.profile(named: chat.profile)?.provider ?? "") : chat.info.provider
    return Button(action: openModels) {
      HStack(spacing: 6) {
        ModelLogo(model: model, provider: provider, size: 17, tint: palette.foregroundMuted)
        ViewThatFits(in: .horizontal) {
          modelText(modelLine()).fixedSize()
          modelText(modelLine(short: true)).fixedSize()
          modelText(modelLine(short: true))
        }
      }
      .padding(.horizontal, 4)
      .frame(height: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(chat.continuesAsNewVersion)
    .layoutPriority(1)
    .accessibilityLabel("Model and effort, \(modelLine())")
    .accessibilityIdentifier("composer.model")
  }

  private func modelText(_ text: String) -> some View {
    Text(text)
      .font(AppFont.sans(15))
      .foregroundStyle(palette.foregroundMuted)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  // MARK: Dictation and send

  private var micButton: some View {
    let isListening = dictation.state == .listening
    return Button {
      if dictation.isActive {
        dictation.stop()
      } else {
        dictationBase = chat.draft
        Task {
          await dictation.start { heard in
            let base = dictationBase.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.draft = base.isEmpty ? heard : dictationBase + (dictationBase.hasSuffix(" ") || dictationBase.hasSuffix("\n") ? "" : " ") + heard
          } failed: { message in
            app.show(message, kind: .failure)
          }
        }
      }
    } label: {
      Group {
        if dictation.state == .starting {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: isListening ? "waveform" : "mic")
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(isListening ? palette.primaryText : palette.iconMuted)
            .symbolEffect(.variableColor.iterative, isActive: isListening)
        }
      }
      .frame(width: 38, height: 42)
      .background(isListening ? palette.selectionFill : Color.clear, in: Circle())
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")
    .accessibilityIdentifier("composer.mic")
  }

  private var sendButton: some View {
    let isOn = chat.canSend || chat.showsStop
    return Button {
      if chat.showsStop {
        Task { await chat.stop() }
      } else {
        send()
      }
    } label: {
      Image(systemName: chat.showsStop ? "stop.fill" : "arrow.up")
        .font(.system(size: chat.showsStop ? 14 : 18, weight: .semibold))
        .foregroundStyle(isOn ? palette.primaryText : palette.iconSubtle)
        .frame(width: 46, height: 46)
        .background(isOn ? palette.primary.opacity(0.26) : palette.subtleStrong, in: Circle())
        .overlay { Circle().strokeBorder(isOn ? palette.primary.opacity(0.35) : Color.clear, lineWidth: 1) }
        .shadow(color: isOn ? palette.primary.opacity(0.25) : .clear, radius: 8, y: 3)
        .contentTransition(.symbolEffect(.replace))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!isOn)
    .accessibilityLabel(chat.showsStop ? "Stop" : chat.sendQueues ? "Queue" : "Send")
  }

  private func importFile(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      app.show("Could not read \(url.lastPathComponent).", kind: .failure)
      return
    }
    let type = UTType(filenameExtension: url.pathExtension)
    if type?.conforms(to: .image) == true {
      chat.addImage(data: data, name: url.lastPathComponent)
    } else {
      chat.addFile(data: data, name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
    }
  }
}

private struct AttachmentChipView: View {
  let attachment: ComposerAttachment
  let remove: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if let thumbnail = attachment.thumbnail {
          Image(uiImage: thumbnail).resizable().scaledToFill()
        } else if attachment.status == .preparing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: attachment.kind == .image ? "photo" : "doc")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.iconMuted)
        }
      }
      .frame(width: 36, height: 36)
      .background(palette.subtle)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

      VStack(alignment: .leading, spacing: 1) {
        Text(attachment.name)
          .font(AppFont.labelMedium)
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detail)
          .font(AppFont.micro)
          .foregroundStyle(isFailed ? palette.dangerForeground : palette.foregroundMuted)
          .lineLimit(1)
      }
      .frame(maxWidth: 130, alignment: .leading)

      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(palette.iconMuted)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(attachment.name)")
    }
    .padding(.leading, 6)
    .padding(.trailing, 2)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: 15))
  }

  private var isFailed: Bool {
    if case .failed = attachment.status { return true }
    return false
  }

  private var detail: String {
    switch attachment.status {
    case .preparing: return "Preparing"
    case .failed(let reason): return reason
    case .ready: return attachment.data.map { Format.bytes($0.count) } ?? ""
    }
  }
}
