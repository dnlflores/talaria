import HermesKit
import SwiftUI

/// A finished file edit as its own message: "Edited Greeting.swift +4 -2" over the colored diff.
/// Open by default like the desktop app's edit cards; tapping the header folds it to that one
/// line and back. A long diff shows its first lines until "Show all" is tapped.
struct EditMessage: View {
  let tool: ToolCall
  let isOpen: Bool
  let toggle: () -> Void
  let inspect: () -> Void
  @Environment(\.palette) private var palette
  @State private var showsAll = false

  /// Lines shown before "Show all": enough to read a small edit whole without one long diff
  /// (Hermes sends up to 80 lines) burying the conversation.
  static let previewLines = 12

  var body: some View {
    if let summary = EditSummary(tool) {
      card(summary)
    }
  }

  private func card(_ summary: EditSummary) -> some View {
    // One file's title and folder already say what the `a/x → b/x` line would; several files
    // keep it to tell their parts apart.
    let lines = summary.paths.count > 1 ? summary.diff.lines : summary.diff.lines.filter { $0.kind != .fileHeader }
    let shown = isOpen ? (showsAll ? lines : Array(lines.prefix(Self.previewLines))) : []
    return VStack(alignment: .leading, spacing: 0) {
      header(summary)
      if isOpen {
        Hairline()
        if summary.paths.count == 1 {
          Text(FileWords.place(FileReference(path: summary.paths[0], origin: .edited)))
            .font(AppFont.mono(11))
            .foregroundStyle(palette.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        DiffView(lines: shown, framed: false)
        if lines.count > shown.count {
          Button {
            showsAll = true
          } label: {
            Text("Show all \(lines.count) lines")
              .font(AppFont.labelMedium)
              .foregroundStyle(palette.primaryText)
              .frame(maxWidth: .infinity, alignment: .leading)
              .frame(minHeight: 40)
              .padding(.horizontal, 10)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .overlay(alignment: .top) { Hairline() }
          .accessibilityIdentifier("transcript.edit.more")
        }
      }
    }
    .background(palette.mdCodeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("transcript.edit.card")
    .onChange(of: isOpen) { _, open in
      if !open { showsAll = false }
    }
  }

  private func header(_ summary: EditSummary) -> some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        HStack(spacing: 8) {
          Image(systemName: ToolPresentation.symbol(for: tool.name))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.transcriptTool)
            .frame(width: 22, height: 22)
          Text(summary.title)
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
          DiffCounts(added: summary.diff.added, removed: summary.diff.removed)
          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.chevron)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .frame(minHeight: 44)
        .padding(.leading, 8)
        .padding(.trailing, isOpen ? 0 : 12)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(summary.title), \(FileWords.changes(added: summary.diff.added, removed: summary.diff.removed))")
      .accessibilityValue(isOpen ? "expanded" : "collapsed")
      .accessibilityHint(isOpen ? "Hides the changes" : "Shows the changes")
      .accessibilityIdentifier("transcript.edit")
      .contextMenu {
        Button("Copy diff", systemImage: "square.on.square") { UIPasteboard.general.string = summary.diff.text }
        Button("Details", systemImage: "info.circle", action: inspect)
      }
      if isOpen {
        CopyButton(text: summary.diff.text, size: 12)
          .padding(.trailing, 4)
      }
    }
  }
}
