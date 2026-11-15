import HermesKit
import SwiftUI

/// Messages written while the agent works, floating above the composer until they go out.
///
/// Each one goes out as the next turn when the reply ends. "Send now" puts it into the running
/// reply instead, so the agent takes it in and answers it right away. Tapping the words takes the
/// message back into the composer to change it.
///
/// The Mac keeps one queue per chat that every device adds to, so the panel shows that queue
/// too: this app's messages it handed over, and any other device's or app's, each named by
/// where it came from. All of them can be sent now, changed or removed from here.
struct QueuePanel: View {
  let chat: ChatModel
  @Environment(\.palette) private var palette

  var body: some View {
    let entries = chat.queue.entries
    let onMac = chat.macQueue
    let count = entries.count + onMac.count
    VStack(alignment: .leading, spacing: 0) {
      header(count: count)
      Hairline()
      if count > 3 {
        ScrollView {
          rows(entries, onMac: onMac)
        }
        .frame(maxHeight: 220)
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

  private func rows(_ entries: [PromptQueue<ComposerAttachment>.Entry], onMac: [ChatModel.MacQueueRow]) -> some View {
    VStack(spacing: 0) {
      // Already in the Mac's queue, so they run first.
      ForEach(Array(onMac.enumerated()), id: \.element.id) { offset, row in
        if offset > 0 { Hairline().padding(.leading, 14) }
        switch row {
        case .mine(let entry): OnMacRow(chat: chat, entry: entry)
        case .other(let queued): OtherDeviceRow(chat: chat, row: queued)
        }
      }
      ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
        if offset > 0 || !onMac.isEmpty { Hairline().padding(.leading, 14) }
        QueueRow(chat: chat, entry: entry)
      }
    }
  }
}

// MARK: Rows

/// Where a queued message came from: "This iPhone", "iPad", "Hermes desktop".
private struct OriginLabel: View {
  let title: String
  let symbol: String
  var onMac = false
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
      Text(onMac ? "\(title) · in your Mac's queue" : title)
        .font(AppFont.caption)
        .lineLimit(1)
    }
    .foregroundStyle(palette.foregroundMuted)
  }

  static func symbol(for origin: QueueOrigin) -> String {
    switch origin {
    case .talaria(let device): device.lowercased().hasPrefix("ipad") ? "ipad" : "iphone"
    case .desktop: "desktopcomputer"
    case .terminal: "terminal"
    case .unknown: "app.dashed"
    }
  }

  @MainActor static func thisDevice(_ chat: ChatModel, onMac: Bool = false) -> OriginLabel {
    let device = chat.deviceKind
    return OriginLabel(title: "This \(device)", symbol: symbol(for: .talaria(device: device)), onMac: onMac)
  }
}

/// The layout every queued row shares: words (tap to change), where it came from, Send now, ✕.
private struct QueueRowLayout<Words: View>: View {
  let accessibilityText: String
  let origin: OriginLabel
  let canEdit: Bool
  let canSendNow: Bool
  let isWorking: Bool
  let sendNowHint: String
  let textID: String
  let rowID: String
  let edit: () -> Void
  let sendNow: () -> Void
  let remove: () -> Void
  @ViewBuilder let words: () -> Words
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Button(action: edit) {
        VStack(alignment: .leading, spacing: 3) {
          words()
          origin
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canEdit || isWorking)
      .accessibilityLabel(accessibilityText)
      .accessibilityHint(canEdit ? "Moves it back into the message field to change it" : "")
      .accessibilityIdentifier(textID)

      if canSendNow { sendNowButton }

      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(palette.iconMuted)
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isWorking)
      .accessibilityLabel("Remove from queue")
      .accessibilityIdentifier("queue.delete")
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 8)
    .contextMenu {
      if canSendNow {
        Button(action: sendNow) { Label("Send now", systemImage: "arrow.up.circle") }
      }
      if canEdit {
        Button(action: edit) { Label("Edit", systemImage: "pencil") }
      }
      Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(rowID)
  }

  private var sendNowButton: some View {
    Button(action: sendNow) {
      ZStack {
        // Keeps the capsule's width while the spinner shows.
        Text("Send now").opacity(isWorking ? 0 : 1)
        if isWorking {
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
    .disabled(isWorking)
    .accessibilityLabel(isWorking ? "Sending" : "Send now")
    .accessibilityHint(sendNowHint)
    .accessibilityIdentifier("queue.sendNow")
  }
}

/// Words plus a line naming the photos and files that go with them.
private struct EntryWords: View {
  let entry: PromptQueue<ComposerAttachment>.Entry
  @Environment(\.palette) private var palette

  var body: some View {
    if !entry.text.isEmpty {
      Text(entry.text)
        .font(AppFont.footnote)
        .foregroundStyle(palette.foreground)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    if !entry.attachments.isEmpty {
      Label(Self.attachmentWords(entry), systemImage: entry.attachments.contains { $0.kind == .image } ? "photo" : "doc")
        .font(AppFont.caption)
        .foregroundStyle(palette.foregroundMuted)
        .labelStyle(.titleAndIcon)
    }
  }

  static func attachmentWords(_ entry: PromptQueue<ComposerAttachment>.Entry) -> String {
    let photos = entry.attachments.count { $0.kind == .image }
    let files = entry.attachments.count - photos
    var parts: [String] = []
    if photos > 0 { parts.append(photos == 1 ? "1 photo" : "\(photos) photos") }
    if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
    return parts.joined(separator: ", ")
  }

  static func spoken(_ entry: PromptQueue<ComposerAttachment>.Entry) -> String {
    [entry.text, attachmentWords(entry)].filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// Waiting here on this device.
private struct QueueRow: View {
  let chat: ChatModel
  let entry: PromptQueue<ComposerAttachment>.Entry

  var body: some View {
    QueueRowLayout(
      accessibilityText: EntryWords.spoken(entry), origin: OriginLabel.thisDevice(chat),
      canEdit: !entry.isAwaitingReceipt, canSendNow: true, isWorking: entry.isDelivering,
      sendNowHint: chat.isBusy ? "The agent takes this message in now and answers it" : "Sends this message",
      textID: "queue.text", rowID: "queue.row",
      edit: { chat.editQueued(entry.id) },
      sendNow: { Task { await chat.sendNow(entry.id) } },
      remove: { chat.deleteQueued(entry.id) }
    ) {
      EntryWords(entry: entry)
    }
  }
}

/// Sent from this device and handed to the Mac's queue (when the chat closed or the app went
/// to sleep). Still this device's message: it can be changed, removed or sent now.
private struct OnMacRow: View {
  let chat: ChatModel
  let entry: PromptQueue<ComposerAttachment>.Entry

  var body: some View {
    let origin = OriginLabel.thisDevice(chat, onMac: true)
    QueueRowLayout(
      accessibilityText: "\(EntryWords.spoken(entry)), from \(origin.title)", origin: origin,
      canEdit: true, canSendNow: chat.isBusy, isWorking: chat.isTakingBack(entry.id),
      sendNowHint: "The agent takes this message in now and answers it",
      textID: "queue.onMac", rowID: "queue.onMac.row",
      edit: { Task { await chat.editOnMac(entry.id) } },
      sendNow: { Task { await chat.sendNowOnMac(entry.id) } },
      remove: { Task { await chat.removeOnMac(entry.id) } }
    ) {
      EntryWords(entry: entry)
    }
  }
}

/// Another device's or app's message in the Mac's queue for this chat.
private struct OtherDeviceRow: View {
  let chat: ChatModel
  let row: QueuedOnMac
  @Environment(\.palette) private var palette

  var body: some View {
    let origin = OriginLabel(title: row.origin.label, symbol: OriginLabel.symbol(for: row.origin))
    let words = row.text.isEmpty ? "Attachments" : row.text
    QueueRowLayout(
      accessibilityText: "\(words), from \(origin.title)", origin: origin,
      // Messages with photos carry no controls: the Mac can only drop them, not hand them on.
      canEdit: row.canSteer, canSendNow: row.canSteer && chat.isBusy, isWorking: chat.isActing(on: row),
      sendNowHint: "The agent takes this message in now and answers it",
      textID: "queue.other", rowID: "queue.other.row",
      edit: { Task { await chat.editFromMac(row) } },
      sendNow: { Task { await chat.sendNowFromMac(row) } },
      remove: { Task { await chat.removeFromMac(row) } }
    ) {
      Text(words)
        .font(AppFont.footnote)
        .foregroundStyle(palette.foreground)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
