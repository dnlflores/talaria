import HermesKit
import SwiftUI

/// The `/` menu: skills and commands for the `/word` being typed, floating just above the
/// composer card like the queue. Tapping one puts its name and a space in the composer.
struct SlashMenuPanel: View {
  let chat: ChatModel
  @Environment(\.palette) private var palette

  /// Rows shown before the list scrolls.
  private static let visibleRows = 5

  var body: some View {
    let items = chat.slashItems
    Group {
      if items.count > Self.visibleRows {
        ScrollView {
          rows(items)
        }
        .frame(maxHeight: CGFloat(Self.visibleRows) * 54)
        .scrollBounceBehavior(.basedOnSize)
      } else {
        rows(items)
      }
    }
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("slash.menu")
  }

  private func rows(_ items: [SlashCompletion]) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
        if offset > 0 { Hairline().padding(.leading, 14) }
        SlashRow(item: item) { chat.pickSlash(item) }
      }
    }
  }
}

private struct SlashRow: View {
  let item: SlashCompletion
  let pick: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: pick) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(AppFont.footnoteMedium)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
          if !item.summary.isEmpty {
            Text(item.summary)
              .font(AppFont.caption)
              .foregroundStyle(palette.foregroundMuted)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(item.kind == .skill ? "Skill" : "Command")
          .font(AppFont.sans(11, .semibold))
          .foregroundStyle(item.kind == .skill ? palette.primaryText : palette.foregroundMuted)
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background(item.kind == .skill ? palette.selectionFill : palette.subtle, in: Capsule())
          .overlay {
            Capsule().strokeBorder(item.kind == .skill ? palette.selectionStroke : palette.border, lineWidth: 1)
          }
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 54)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(item.name), \(item.kind == .skill ? "skill" : "command")")
    .accessibilityHint(item.summary)
    .accessibilityIdentifier("slash.row")
  }
}

/// What a command answered, under it in the chat: only on this phone, never sent to the model or
/// stored on the Mac.
struct SlashNoticeCard: View {
  let item: TranscriptItem
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "terminal")
          .font(.system(size: 11, weight: .semibold))
        Text(item.command)
          .font(AppFont.mono(12, weight: .semibold))
          .lineLimit(1)
        Text("Only on this phone")
          .font(AppFont.micro)
        Spacer(minLength: 4)
        CopyButton(text: item.text, size: 12)
      }
      .foregroundStyle(palette.foregroundMuted)
      Text(item.text)
        .font(AppFont.mono(12))
        .foregroundStyle(palette.foreground)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .padding(.top, 4)
    .padding(.bottom, 10)
    .glassCard(radius: 14, fill: palette.card, shadow: false)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("transcript.notice")
  }
}
