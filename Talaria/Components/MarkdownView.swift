import MarkdownBlocks
import SwiftUI

/// Type sizes for a block of Markdown: answers read at body size, work-log notes smaller.
struct MarkdownStyle: Equatable {
  var size: CGFloat = 16
  var codeSize: CGFloat = 12.5
  var blockSpacing: CGFloat = 12
  var lineSpacing: CGFloat = 4
  var isMuted = false

  static let answer = MarkdownStyle()
  static let note = MarkdownStyle(size: 14, codeSize: 12, blockSpacing: 8, lineSpacing: 3, isMuted: true)
}

/// Renders Markdown as native text. Long lines wrap; nothing scrolls sideways.
struct MarkdownView: View {
  let text: String
  var style: MarkdownStyle = .answer

  var body: some View {
    let blocks = MarkdownCache.blocks(for: text)
    VStack(alignment: .leading, spacing: style.blockSpacing) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockView(block: block, style: style)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Parsing is cheap but a streaming reply re-renders on every token, so keep recent results.
@MainActor
private enum MarkdownCache {
  private static var entries: [String: [MarkdownBlock]] = [:]
  private static var order: [String] = []

  static func blocks(for text: String) -> [MarkdownBlock] {
    if let hit = entries[text] { return hit }
    let parsed = MarkdownParser.parse(text)
    entries[text] = parsed
    order.append(text)
    if order.count > 200 {
      for key in order.prefix(80) { entries[key] = nil }
      order.removeFirst(80)
    }
    return parsed
  }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock
  let style: MarkdownStyle
  @Environment(\.palette) private var palette

  var body: some View {
    switch block {
    case .paragraph(let source):
      InlineText(source: source, style: style)

    case .heading(let level, let source):
      InlineText(source: source, style: style, weight: .semibold, sizeDelta: level == 1 ? 5 : level == 2 ? 3 : level == 3 ? 1 : 0)
        .padding(.top, level <= 2 ? 4 : 0)

    case .code(let language, let code):
      CodeBlockView(language: language, code: code, style: style)

    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(ordered: ordered, number: start + offset, checkbox: item.checkbox)
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child, style: style)
              }
            }
          }
        }
      }

    case .quote(let blocks):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
          MarkdownBlockView(block: child, style: style)
        }
      }
      .padding(.leading, 12)
      .padding(.vertical, 2)
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1.5).fill(palette.foregroundMuted.opacity(0.45)).frame(width: 3)
      }

    case .table(let header, let rows):
      TableView(header: header, rows: rows, style: style)

    case .rule:
      Rectangle().fill(palette.mdHr).frame(height: 1).padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private func marker(ordered: Bool, number: Int, checkbox: Bool?) -> some View {
    if let checkbox {
      Image(systemName: checkbox ? "checkmark.square.fill" : "square")
        .font(.system(size: style.size - 2))
        .foregroundStyle(checkbox ? palette.primaryText : palette.iconMuted)
    } else if ordered {
      Text("\(number).")
        .font(AppFont.sans(style.size))
        .monospacedDigit()
        .foregroundStyle(palette.foregroundMuted)
    } else {
      Text("•")
        .font(AppFont.sans(style.size, .bold))
        .foregroundStyle(palette.foregroundMuted)
    }
  }
}

/// A run of text with inline Markdown: emphasis, code, links, strikethrough.
struct InlineText: View {
  let source: String
  var style: MarkdownStyle = .answer
  var weight: AppFont.Weight = .regular
  var sizeDelta: CGFloat = 0
  @Environment(\.palette) private var palette

  var body: some View {
    Text(attributed)
      .lineSpacing(style.lineSpacing)
      .foregroundStyle(style.isMuted ? palette.foregroundSecondary : palette.mdBody)
      .tint(palette.mdLink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attributed: AttributedString {
    let size = style.size + sizeDelta
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible)
    var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    text.font = AppFont.sans(size, weight)
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) {
        text[run.range].font = AppFont.mono(size - 2.5)
        text[run.range].backgroundColor = palette.mdCodeBg
        text[run.range].foregroundColor = palette.mdCodeText
      } else if intent.contains(.stronglyEmphasized) {
        text[run.range].font = AppFont.sans(size, weight == .regular ? .semibold : .bold)
        if !style.isMuted { text[run.range].foregroundColor = palette.mdStrong }
      } else if intent.contains(.emphasized) {
        text[run.range].font = .custom("DMSans-Italic", size: size, relativeTo: .body)
      }
      if intent.contains(.strikethrough) { text[run.range].strikethroughStyle = .single }
      if run.link != nil {
        text[run.range].foregroundColor = palette.mdLink
        text[run.range].underlineStyle = .single
      }
    }
    return text
  }
}

private struct CodeBlockView: View {
  let language: String
  let code: String
  let style: MarkdownStyle
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "code" : language)
          .font(AppFont.mono(11))
          .foregroundStyle(palette.foregroundMuted)
        Spacer(minLength: 8)
        CopyButton(text: code, size: 12)
      }
      .padding(.leading, 12)
      .padding(.trailing, 6)
      .frame(height: 30)
      Rectangle().fill(palette.border).frame(height: 1)
      Text(code)
        .font(AppFont.mono(style.codeSize))
        .lineSpacing(3)
        .foregroundStyle(palette.mdCodeText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
    .background(palette.mdCodeBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
  }
}

private struct TableView: View {
  let header: [String]
  let rows: [[String]]
  let style: MarkdownStyle
  @Environment(\.palette) private var palette

  var body: some View {
    let columns = max(header.count, rows.map(\.count).max() ?? 0)
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0..<columns, id: \.self) { column in
          cell(column < header.count ? header[column] : "", isHeader: true)
        }
      }
      .background(palette.subtle)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        Rectangle().fill(palette.border).frame(height: 1)
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            cell(column < row.count ? row[column] : "", isHeader: false)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
  }

  private func cell(_ text: String, isHeader: Bool) -> some View {
    var cellStyle = style
    cellStyle.size = max(style.size - 2, 12)
    cellStyle.lineSpacing = 2
    return InlineText(source: text, style: cellStyle, weight: isHeader ? .semibold : .regular)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
  }
}
