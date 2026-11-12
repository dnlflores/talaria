import HermesKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - In the transcript

/// The files a finished turn wrote, edited or delivered, under its answer. Pictures show as
/// pictures; other files as chips. Tapping one opens it.
struct TurnFilesView: View {
  let turn: TurnFiles
  let chat: ChatModel
  @Environment(\.palette) private var palette
  @State private var opened: FileReference?
  @State private var showsAll = false

  private static let shown = 3
  private static let picturesShown = 6

  var body: some View {
    let pictures = turn.files.filter { $0.kind == .image }
    let others = turn.files.filter { $0.kind != .image }
    let hidden = max(0, pictures.count - Self.picturesShown) + max(0, others.count - Self.shown)
    VStack(alignment: .leading, spacing: 6) {
      if !pictures.isEmpty {
        PictureGallery(
          pictures: pictures.prefix(Self.picturesShown).map { .remote(path: $0.path) },
          profile: chat.profile, storedID: chat.storedID)
        .padding(.bottom, others.isEmpty ? 0 : 2)
      }
      ForEach(others.prefix(Self.shown)) { file in
        Button {
          opened = file
        } label: {
          FileChip(file: file)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.file")
      }
      if hidden > 0 {
        Button {
          showsAll = true
        } label: {
          Text("Show all \(turn.files.count) files")
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.primaryText)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(item: $opened) { file in
      FilePreviewSheet(file: file, profile: chat.profile, storedID: chat.storedID)
    }
    .sheet(isPresented: $showsAll) {
      ChatFilesSheet(files: turn.files, chat: chat, title: "Files from this reply")
    }
  }
}

/// One file as a compact chip: its type, its name, and where it lives.
struct FileChip: View {
  let file: FileReference
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 9) {
      FileIcon(kind: file.kind, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .font(AppFont.labelMedium)
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(FileWords.place(file))
          .font(AppFont.mono(11))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 6)
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.chevron)
    }
    .padding(.leading, 6)
    .padding(.trailing, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: 420, alignment: .leading)
    .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(file.name), \(FileWords.origin(file.origin))")
    .accessibilityHint("Opens the file")
  }
}

/// A rounded tile with a symbol for the kind of file.
struct FileIcon: View {
  let kind: FileReference.Kind
  var size: CGFloat = 34
  @Environment(\.palette) private var palette

  var body: some View {
    Image(systemName: FileWords.symbol(kind))
      .font(.system(size: size * 0.42, weight: .medium))
      .foregroundStyle(palette.icon)
      .frame(width: size, height: size)
      .background(palette.subtle, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
      .accessibilityHidden(true)
  }
}

enum FileWords {
  static func symbol(_ kind: FileReference.Kind) -> String {
    switch kind {
    case .image: return "photo"
    case .pdf: return "doc.richtext"
    case .audio: return "waveform"
    case .video: return "film"
    case .text: return "doc.text"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .table: return "tablecells"
    case .archive: return "doc.zipper"
    case .document: return "doc"
    case .other: return "doc"
    }
  }

  static func origin(_ origin: FileReference.Origin) -> String {
    switch origin {
    case .written: return "Written"
    case .edited: return "Edited"
    case .delivered: return "Delivered"
    case .mentioned: return "Mentioned"
    }
  }

  /// The folder, shortened: `~` for the home folder, and the chat's folder when the path is relative.
  static func place(_ file: FileReference) -> String {
    let folder = file.folder
    if folder.isEmpty { return "working folder" }
    if let range = folder.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
      return "~" + folder[range.upperBound...]
    }
    return folder
  }
}

// MARK: - Every file in a chat

/// The list behind "Files" in a chat's menu: everything the chat made or touched, newest first.
struct ChatFilesSheet: View {
  let files: [FileReference]
  let chat: ChatModel
  var title = "Files"
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss
  @State private var opened: FileReference?

  var body: some View {
    NavigationStack {
      ScrollView {
        if files.isEmpty {
          EmptyStateView(
            symbol: "doc.on.doc", title: "No files yet",
            text: "Files this chat writes, edits or hands over show up here.")
        } else {
          VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { offset, file in
              if offset > 0 { GroupDivider(inset: 62) }
              Button {
                opened = file
              } label: {
                row(file)
              }
              .buttonStyle(RowButtonStyle())
              .contextMenu {
                Button {
                  UIPasteboard.general.string = file.path
                } label: {
                  Label("Copy path", systemImage: "doc.on.clipboard")
                }
              }
              .accessibilityIdentifier("files.row")
            }
          }
          .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
          .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 20)
        }
      }
      .background(palette.sheetSolid.ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .sheet(item: $opened) { file in
      FilePreviewSheet(file: file, profile: chat.profile, storedID: chat.storedID)
    }
  }

  private var sorted: [FileReference] {
    files.sorted { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
  }

  private func row(_ file: FileReference) -> some View {
    HStack(spacing: 12) {
      FileIcon(kind: file.kind, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.name)
          .font(AppFont.bodyMedium)
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(FileWords.place(file))
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(FileWords.origin(file.origin))
          .font(AppFont.label)
          .foregroundStyle(file.origin == .mentioned ? palette.foregroundMuted : palette.foregroundSecondary)
        if let timestamp = file.timestamp {
          Text(Format.ago(timestamp)).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

// MARK: - One file

/// Shows a file from the Mac: text and code as wrapped text, everything else through Quick Look.
/// Share hands the downloaded file to the system sheet (Save to Files, AirDrop, another app).
struct FilePreviewSheet: View {
  let file: FileReference
  let profile: String
  let storedID: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss

  private enum Content {
    case loading
    case text(FilePreview)
    case local(URL)
    case failed(String)
  }

  @State private var content: Content = .loading
  @State private var downloaded: URL?
  @State private var isDownloading = false
  @State private var shareURL: ShareItem?
  @State private var showsSource = false

  var body: some View {
    NavigationStack {
      Group {
        switch content {
        case .loading:
          VStack(spacing: 12) {
            ProgressView()
            Text("Opening \(file.name)").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let preview):
          textBody(preview)
        case .local(let url):
          QuickLookView(url: url)
            .ignoresSafeArea(edges: .bottom)
        case .failed(let message):
          ScrollView {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can't open this file", text: message)
          }
        }
      }
      .background(palette.sheetSolid.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          VStack(spacing: 1) {
            Text(file.name)
              .font(AppFont.sans(15, .semibold))
              .foregroundStyle(palette.foreground)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(subtitle)
              .font(AppFont.micro)
              .foregroundStyle(palette.foregroundMuted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .frame(maxWidth: 240)
          .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          if case .text(let preview) = content, file.fileExtension == "md" || file.fileExtension == "markdown", !preview.isBinary {
            Button {
              withAnimation(.easeInOut(duration: 0.2)) { showsSource.toggle() }
            } label: {
              Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(showsSource ? "Show formatted" : "Show source")
          }
          Button {
            Task { await share() }
          } label: {
            if isDownloading {
              ProgressView()
            } else {
              Image(systemName: "square.and.arrow.up")
            }
          }
          .disabled(isDownloading || isFailed)
          .accessibilityLabel("Share or save")
          .accessibilityIdentifier("file.share")
        }
      }
    }
    .presentationDetents([.large])
    .task { await load() }
    .sheet(item: $shareURL) { item in
      ShareSheet(url: item.url)
        .presentationDetents([.medium, .large])
    }
  }

  private var isFailed: Bool {
    if case .failed = content { return true }
    return false
  }

  private var subtitle: String {
    var parts = [FileWords.place(file)]
    if case .text(let preview) = content, preview.byteSize > 0 { parts.append(Format.bytes(preview.byteSize)) }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func textBody(_ preview: FilePreview) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if preview.isTruncated {
          Text("Showing the first part of a \(Format.bytes(preview.byteSize)) file. Share it to see all of it.")
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundMuted)
        }
        if (file.fileExtension == "md" || file.fileExtension == "markdown") && !showsSource {
          MarkdownView(text: preview.text)
            .textSelection(.enabled)
        } else if preview.text.isEmpty {
          Text("This file is empty.").font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
        } else {
          Text(preview.text)
            .font(AppFont.mono(12))
            .lineSpacing(3)
            .foregroundStyle(palette.mdCodeText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(palette.mdCodeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
        }
      }
      .padding(Metrics.screenPadding)
      .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("file.text")
  }

  private func load() async {
    guard let client = app.client else { return }
    do {
      if file.isTextual || file.kind == .other {
        let preview = try await client.filePreview(path: file.path, profile: profile, storedID: storedID)
        if !preview.isBinary {
          content = .text(preview)
          return
        }
      }
      let url = try await client.downloadFile(path: file.path, profile: profile, storedID: storedID)
      downloaded = url
      content = .local(url)
    } catch {
      content = .failed(FileWords.failure(error))
    }
  }

  private func share() async {
    if let downloaded {
      shareURL = ShareItem(url: downloaded)
      return
    }
    guard let client = app.client else { return }
    isDownloading = true
    defer { isDownloading = false }
    do {
      let url = try await client.downloadFile(path: file.path, profile: profile, storedID: storedID)
      downloaded = url
      shareURL = ShareItem(url: url)
    } catch {
      app.show("Could not download \(file.name): \(FileWords.failure(error))", kind: .failure)
    }
  }
}

extension FileWords {
  /// The server's reason in plain words.
  static func failure(_ error: any Error) -> String {
    if case HermesError.http(let status, let message) = error {
      switch status {
      case 404: return "It is not on your Mac anymore, or it was never saved there."
      case 403: return "Your Mac does not let this app read that folder."
      case 413: return "It is too large to send to the phone."
      default: return message
      }
    }
    return error.localizedDescription
  }
}

struct ShareItem: Identifiable {
  let url: URL
  var id: URL { url }
}

/// Quick Look inside our own sheet: images, PDFs, audio, video and office documents.
struct QuickLookView: UIViewControllerRepresentable {
  let url: URL

  func makeCoordinator() -> Coordinator { Coordinator(url: url) }

  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: QLPreviewController, context: Context) {
    if context.coordinator.url != url {
      context.coordinator.url = url
      controller.reloadData()
    }
  }

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    var url: URL
    init(url: URL) { self.url = url }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
      url as NSURL
    }
  }
}

/// The system share sheet for one file.
struct ShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
