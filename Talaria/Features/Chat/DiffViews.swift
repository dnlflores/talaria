import HermesKit
import SwiftUI

/// "+12 -3": the lines an edit added and removed, green and red.
struct DiffCounts: View {
  let added: Int
  let removed: Int
  var size: CGFloat = 11
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(added)").foregroundStyle(palette.diffAddedText)
      Text("-\(removed)").foregroundStyle(palette.diffRemovedText)
    }
    .font(AppFont.mono(size).weight(.semibold))
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(FileWords.changes(added: added, removed: removed))
  }
}

/// An edit's diff, one line per row: added lines on a soft green band, removed on a soft red one,
/// hunk headers muted. Long lines wrap; nothing scrolls sideways.
struct DiffView: View {
  let lines: [DiffLine]
  /// Its own rounded box; off inside a card that draws one (an edit message).
  var framed = true
  @Environment(\.palette) private var palette

  /// Hermes caps its diffs at 80 lines; this only guards against something far larger.
  private static let shownLines = 400

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.prefix(Self.shownLines).enumerated()), id: \.offset) { _, line in
        row(line)
      }
      if lines.count > Self.shownLines {
        Text("\(lines.count - Self.shownLines) more lines. Copy the diff to see all of it.")
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundMuted)
          .padding(.horizontal, 10)
          .padding(.top, 6)
      }
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(framed ? palette.mdCodeBg : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: framed ? 12 : 0, style: .continuous))
    .overlay {
      if framed { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("diff.view")
  }

  private func row(_ line: DiffLine) -> some View {
    Text(line.text.isEmpty ? " " : line.text)
      .font(AppFont.mono(12).weight(line.kind == .fileHeader ? .semibold : .regular))
      .lineSpacing(2)
      .foregroundStyle(foreground(line.kind))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 1.5)
      // In a Rectangle: a bare color background is drawn with rounded ends on iOS 27, which
      // notched every line's band.
      .background(band(line.kind), in: Rectangle())
      .padding(.top, line.kind == .hunk ? 4 : 0)
      .accessibilityLabel(Self.spoken(line))
      .accessibilityIdentifier("diff.line")
  }

  private func foreground(_ kind: DiffLine.Kind) -> Color {
    switch kind {
    case .added, .removed, .context: return palette.mdCodeText
    case .hunk: return palette.foregroundMuted
    case .fileHeader: return palette.foregroundSecondary
    }
  }

  private func band(_ kind: DiffLine.Kind) -> Color {
    switch kind {
    case .added: return palette.diffAdded
    case .removed: return palette.diffRemoved
    case .hunk, .fileHeader, .context: return .clear
    }
  }

  static func spoken(_ line: DiffLine) -> String {
    switch line.kind {
    case .added: return "Added: \(line.content)"
    case .removed: return "Removed: \(line.content)"
    case .fileHeader: return "File: \(line.content)"
    case .hunk, .context: return line.content.isEmpty ? "Blank line" : line.content
    }
  }
}

/// Every edit a file got, one after another: "Edit 1", "Edit 2" when there are several, each with
/// its counts and a copy button.
struct FileChangesView: View {
  let diffs: [EditDiff]
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(diffs.enumerated()), id: \.offset) { index, diff in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            if diffs.count > 1 {
              Text("EDIT \(index + 1)")
                .font(AppFont.sans(11, .semibold))
                .kerning(0.6)
                .foregroundStyle(palette.foregroundMuted)
                .accessibilityLabel("Edit \(index + 1)")
            }
            DiffCounts(added: diff.added, removed: diff.removed)
            Spacer()
            CopyButton(text: diff.text, size: 12)
          }
          DiffView(lines: diff.lines)
        }
      }
    }
  }
}

extension FileWords {
  /// "12 lines added, 3 removed".
  static func changes(added: Int, removed: Int) -> String {
    "\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed"
  }
}
