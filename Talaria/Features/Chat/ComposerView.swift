import HermesKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The floating glass composer: attach, type, send or stop.
struct ComposerView: View {
  @Bindable var chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @FocusState private var isFocused: Bool
  @State private var showsPhotos = false
  @State private var showsFiles = false
  @State private var photoItems: [PhotosPickerItem] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if chat.queue.isShowing {
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

      HStack(alignment: .bottom, spacing: 2) {
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
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(palette.icon)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach")

        TextField(placeholder, text: $chat.draft, axis: .vertical)
          .lineLimit(1...8)
          .font(AppFont.body)
          .foregroundStyle(palette.foreground)
          .focused($isFocused)
          .accessibilityIdentifier("composer.input")
          .padding(.vertical, 9)
          .frame(minHeight: 40)

        sendButton
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.25), value: chat.queue.entries.map(\.id) + chat.queue.onMac.map(\.id))
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

  private var sendButton: some View {
    Button {
      if chat.showsStop {
        Task { await chat.stop() }
      } else {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await chat.send() }
      }
    } label: {
      Image(systemName: chat.showsStop ? "stop.fill" : "arrow.up")
        .font(.system(size: chat.showsStop ? 13 : 16, weight: .semibold))
        .foregroundStyle(palette.primaryForeground)
        .frame(width: 34, height: 34)
        .background(palette.primary.opacity(chat.canSend || chat.showsStop ? 1 : 0.35), in: Circle())
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!chat.canSend && !chat.showsStop)
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
