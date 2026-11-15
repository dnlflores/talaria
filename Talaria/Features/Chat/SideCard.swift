import HermesKit
import SwiftUI

/// A `/btw` question or `/bg` task in the conversation: a small notice while it runs, then its
/// answer as its own card, headed with what was asked (the desktop app's `[btw "question"]`).
/// Only this device shows them; the Mac never stores side answers.
struct SideCard: View {
  let item: TranscriptItem

  var body: some View {
    if let task = item.side {
      if task.answer == nil {
        SideNotice(task: task)
      } else {
        SideAnswerCard(task: task, timestamp: item.timestamp)
      }
    }
  }
}

/// "Asking on the side" or "Running in the background", with the question or task.
private struct SideNotice: View {
  let task: SideTask
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: task.kind == .btw ? "bubble.left.and.text.bubble.right" : "clock.arrow.circlepath")
        .font(.system(size: 12, weight: .semibold))
      VStack(alignment: .leading, spacing: 2) {
        Text(task.kind == .btw ? "Asking on the side" : "Running in the background")
          .font(AppFont.labelMedium)
          .foregroundStyle(palette.foregroundSecondary)
        Text(task.prompt)
          .font(AppFont.label)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(palette.foregroundMuted)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("transcript.sideNotice")
  }
}

/// The answer, rendered as Markdown; long-press copies it. A failure says so in plain words.
private struct SideAnswerCard: View {
  let task: SideTask
  let timestamp: Double?
  @Environment(\.palette) private var palette

  private var title: String {
    switch task.kind {
    case .btw: task.isFailed ? "Side question failed" : "btw"
    case .background: task.isFailed ? "Background task failed" : "Background task"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: task.isFailed ? "exclamationmark.triangle" : task.kind == .btw ? "bubble.left.and.text.bubble.right" : "checkmark.circle")
          .font(.system(size: 11, weight: .semibold))
        Text(title)
          .font(AppFont.labelMedium)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(Format.clock(timestamp))
          .font(AppFont.caption)
      }
      .foregroundStyle(task.isFailed ? palette.dangerForeground : palette.foregroundMuted)
      if !task.prompt.isEmpty {
        Text(task.kind == .btw ? "\u{201C}\(task.prompt)\u{201D}" : task.prompt)
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundSecondary)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("transcript.side.prompt")
      }
      if task.isFailed {
        Text(task.shownAnswer)
          .font(AppFont.body)
          .foregroundStyle(palette.foreground)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        MarkdownView(text: task.shownAnswer)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .glassCard(radius: 14, fill: palette.card, shadow: false)
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contextMenu {
      Button("Copy", systemImage: "square.on.square") { UIPasteboard.general.string = task.shownAnswer }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(task.isFailed ? "transcript.side.failed" : "transcript.side")
  }
}
