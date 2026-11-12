import HermesKit
import SwiftUI

/// Messages written while the agent works, floating above the composer until they go out.
///
/// Each one goes out as the next turn when the reply ends. "Send now" puts it into the running
/// reply instead, so the agent takes it in and answers it right away. Tapping the words takes the
/// message back into the composer to change it.
struct QueuePanel: View {
  let chat: ChatModel
  @Environment(\.palette) private var palette

  var body: some View {
    let entries = chat.queue.entries
    let onMac = chat.queue.onMac
    VStack(alignment: .leading, spacing: 0) {
      header(count: entries.count + onMac.count)
      Hairline()
      if entries.count + onMac.count > 3 {
        ScrollView {
          rows(entries, onMac: onMac)
        }
        .frame(maxHeight: 196)
      } else {
        rows(entries, onMac: onMac)
      }
    }
    .glassEffect(.regular, in: .rect(cornerRadius: 18))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queue.panel")
  }

  private func header(count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: chat.queue.isPaused ? "pause.circle" : "clock")
        .font(.system(size: 11, weight: .semibold))
      Text(count == 1 ? "1 queued" : "\(count) queued")
        .font(AppFont.sans(11, .semibold))
        .textCase(.uppercase)
        .kerning(0.6)
      Spacer(minLength: 8)
      if chat.queue.isPaused {
        Text("Paused").font(AppFont.caption)
        Button {
          chat.resumeQueue()
        } label: {
          Text("Resume")
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.primaryText)
            .frame(height: 26)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queue.resume")
      } else if chat.isBusy || chat.queue.isEmpty {
        Text("Goes out after this reply").font(AppFont.caption)
      } else {
        Text("Sending").font(AppFont.caption)
      }
    }
    .foregroundStyle(palette.foregroundMuted)
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .frame(minHeight: 34)
  }

  private func rows(_ entries: [PromptQueue<ComposerAttachment>.Entry], onMac: [PromptQueue<ComposerAttachment>.Entry]) -> some View {
    VStack(spacing: 0) {
      // Handed to the Mac first, so they run first.
      ForEach(Array(onMac.enumerated()), id: \.element.id) { offset, entry in
        if offset > 0 { Hairline().padding(.leading, 14) }
        OnMacRow(entry: entry)
      }
      ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
        if offset > 0 || !onMac.isEmpty { Hairline().padding(.leading, 14) }
        QueueRow(chat: chat, entry: entry)
      }
    }
  }
}

/// A message the Mac holds in its own queue (handed over when the phone went to sleep). It runs
/// after the reply; nothing to do here but wait.
private struct OnMacRow: View {
  let entry: PromptQueue<ComposerAttachment>.Entry
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      Text(entry.text.isEmpty ? "Attachments" : entry.text)
        .font(AppFont.footnote)
        .foregroundStyle(palette.foregroundSecondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Label("On your Mac", systemImage: "macbook")
        .font(AppFont.caption)
        .foregroundStyle(palette.foregroundMuted)
        .labelStyle(.titleAndIcon)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("queue.onMac")
  }
}

private struct QueueRow: View {
  let chat: ChatModel
  let entry: PromptQueue<ComposerAttachment>.Entry
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Button {
        chat.editQueued(entry.id)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          if !entry.text.isEmpty {
            Text(entry.text)
              .font(AppFont.footnote)
              .foregroundStyle(palette.foreground)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !entry.attachments.isEmpty {
            Label(attachmentWords, systemImage: entry.attachments.contains { $0.kind == .image } ? "photo" : "doc")
              .font(AppFont.caption)
              .foregroundStyle(palette.foregroundMuted)
              .labelStyle(.titleAndIcon)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityText)
      .accessibilityHint("Moves it back into the message field to change it")

      sendNowButton

      Button {
        chat.deleteQueued(entry.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(palette.iconMuted)
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(entry.isDelivering)
      .accessibilityLabel("Remove from queue")
      .accessibilityIdentifier("queue.delete")
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 8)
    .contextMenu {
      Button {
        Task { await chat.sendNow(entry.id) }
      } label: {
        Label("Send now", systemImage: "arrow.up.circle")
      }
      Button {
        chat.editQueued(entry.id)
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      Button(role: .destructive) {
        chat.deleteQueued(entry.id)
      } label: {
        Label("Remove", systemImage: "trash")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("queue.row")
  }

  private var sendNowButton: some View {
    Button {
      Task { await chat.sendNow(entry.id) }
    } label: {
      ZStack {
        // Keeps the capsule's width while the spinner shows.
        Text("Send now").opacity(entry.isDelivering ? 0 : 1)
        if entry.isDelivering {
          ProgressView().controlSize(.mini).tint(palette.primaryForeground)
        }
      }
      .font(AppFont.labelMedium)
      .foregroundStyle(palette.primaryForeground)
      .padding(.horizontal, 11)
      .frame(height: 28)
      .background(palette.primary, in: Capsule())
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(entry.isDelivering)
    .accessibilityLabel(entry.isDelivering ? "Sending" : "Send now")
    .accessibilityHint(chat.isBusy ? "The agent takes this message in now and answers it" : "Sends this message")
    .accessibilityIdentifier("queue.sendNow")
  }

  private var attachmentWords: String {
    let photos = entry.attachments.count { $0.kind == .image }
    let files = entry.attachments.count - photos
    var parts: [String] = []
    if photos > 0 { parts.append(photos == 1 ? "1 photo" : "\(photos) photos") }
    if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
    return parts.joined(separator: ", ")
  }

  private var accessibilityText: String {
    [entry.text, attachmentWords].filter { !$0.isEmpty }.joined(separator: ", ")
  }
}
