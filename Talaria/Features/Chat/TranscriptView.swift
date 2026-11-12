import HermesKit
import SwiftUI

/// The scrolling conversation. It follows the newest message while you are at the bottom
/// and leaves you alone once you scroll up.
///
/// The rows are laid out eagerly (a lazy stack with a bottom anchor mis-places its content
/// when a row changes height), so only the newest `visibleLimit` rows are shown until asked.
struct TranscriptView: View {
  let chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var position = ScrollPosition(edge: .bottom)
  /// True while the view should keep the newest content in sight.
  @State private var isFollowing = true
  @State private var isUserScrolling = false
  @State private var visibleLimit = TranscriptView.pageSize
  @State private var expanded: Set<UUID> = []
  @State private var inspected: ToolCall?

  private static let pageSize = 60

  private struct Extent: Equatable {
    var content: CGFloat
    var container: CGFloat
  }

  var body: some View {
    let rows = chat.rows
    let hidden = max(0, rows.count - visibleLimit)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if chat.isLoading {
          TranscriptPlaceholder()
        } else if chat.isEmpty {
          EmptyChat(profile: chat.profile)
        } else {
          if hidden > 0 {
            Button {
              showEarlier(firstVisible: rows[hidden].id)
            } label: {
              Text(hidden == 1 ? "Show 1 earlier message" : "Show \(min(hidden, Self.pageSize)) earlier messages")
                .font(AppFont.labelMedium)
                .foregroundStyle(palette.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
          }
          ForEach(rows.suffix(visibleLimit)) { row in
            rowView(row).id(row.id)
          }
          if let activity = chat.activity {
            WorkingRow(activity: activity, startedAt: chat.turnStartedAt)
              .transition(.opacity)
          }
        }
      }
      .animation(.easeInOut(duration: 0.2), value: chat.isStreaming)
      .padding(.horizontal, Metrics.screenPadding)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .scrollPosition($position)
    .scrollDismissesKeyboard(.interactively)
    .onScrollPhaseChange { _, phase in
      isUserScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
    }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 60
    } action: { _, atBottom in
      // Only a person's scrolling can stop the following; content growing under a parked view must not.
      if isUserScrolling {
        isFollowing = atBottom
      } else if atBottom {
        isFollowing = true
      }
    }
    .onScrollGeometryChange(for: Extent.self) { geometry in
      Extent(content: geometry.contentSize.height, container: geometry.containerSize.height)
    } action: { _, _ in
      // New text, a new row, or the keyboard: keep the end in sight while following.
      if isFollowing, !isUserScrolling { position.scrollTo(edge: .bottom) }
    }
    .onChange(of: chat.scrollToEnd) {
      isFollowing = true
      withAnimation(.snappy(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }
    .overlay(alignment: .bottom) {
      if !isFollowing, !chat.isEmpty, !chat.isLoading {
        Button {
          isFollowing = true
          withAnimation(.snappy(duration: 0.3)) { position.scrollTo(edge: .bottom) }
        } label: {
          Image(systemName: "arrow.down")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.foreground)
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityLabel("Jump to latest")
      }
    }
    .animation(.snappy(duration: 0.2), value: isFollowing)
    .sheet(item: $inspected) { tool in
      ToolDetailSheet(tool: tool)
        .presentationDetents([.medium, .large])
    }
  }

  /// Reveals another page above and keeps the row that was on top where it was.
  private func showEarlier(firstVisible: UUID) {
    isFollowing = false
    visibleLimit += Self.pageSize
    position.scrollTo(id: firstVisible, anchor: .top)
  }

  private func toggle(_ id: UUID) {
    // Opening a work log is reading, not following: the view should stay where the tap was.
    isFollowing = false
    withAnimation(.snappy(duration: 0.25)) {
      if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
  }

  @ViewBuilder
  private func rowView(_ row: TranscriptRow) -> some View {
    switch row {
    case .user(let item):
      UserBubble(item: item)
    case .answer(let item):
      AnswerView(item: item)
    case .work(let group):
      WorkLogView(
        group: group, isExpanded: expanded.contains(group.id),
        toggle: { toggle(group.id) },
        inspect: { inspected = $0 })
    case .question(let item):
      ClarifyCard(item: item, botTitle: app.title(forProfile: chat.profile)) { requestID, values in
        chat.answer(requestID: requestID, values: values)
      }
    case .system(let item):
      SystemNote(text: item.text)
    case .files(let turn):
      TurnFilesView(turn: turn, chat: chat)
    }
  }
}

// MARK: - Messages

private struct UserBubble: View {
  let item: TranscriptItem
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      if !item.attachments.isEmpty {
        HStack(spacing: 6) {
          ForEach(item.attachments) { attachment in
            AttachmentThumbnail(name: attachment.name, image: attachment.thumbnail.flatMap(UIImage.init(data:)), isImage: attachment.kind == .image)
          }
        }
      }
      if !item.text.isEmpty {
        Text(item.text)
          .font(AppFont.body)
          .lineSpacing(4)
          .foregroundStyle(palette.userBubbleForeground)
          .textSelection(.enabled)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(palette.userBubble, in: RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous))
          .opacity(item.isPending ? 0.6 : 1)
          .accessibilityIdentifier("transcript.user")
      }
      HStack(spacing: 0) {
        Text(meta)
          .font(AppFont.caption)
          .foregroundStyle(item.isFailed ? palette.dangerForeground : palette.foregroundMuted)
        if !item.text.isEmpty, !item.isPending, !item.isFailed { CopyButton(text: item.text, size: 12) }
      }
      .frame(minHeight: 22)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 44)
  }

  private var meta: String {
    if item.isFailed { return "Not sent" }
    if item.isPending { return "Sending" }
    return Format.clock(item.timestamp)
  }
}

struct AttachmentThumbnail: View {
  let name: String
  let image: UIImage?
  let isImage: Bool
  @Environment(\.palette) private var palette

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
      } else {
        HStack(spacing: 6) {
          Image(systemName: isImage ? "photo" : "doc")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.iconMuted)
          Text(name)
            .font(AppFont.label)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: 180)
        .background(palette.groupedCard)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityLabel(name)
  }
}

private struct AnswerView: View {
  let item: TranscriptItem
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // MEDIA: lines become file chips under the turn, so the answer does not repeat them as text.
      MarkdownView(text: item.isStreaming ? item.text : FileExtraction.hidingMediaLines(item.text))
        .textSelection(.enabled)
        .accessibilityIdentifier("transcript.answer")
      if !item.isStreaming {
        HStack(spacing: 0) {
          CopyButton(text: item.text, size: 12)
          Text(Format.clock(item.timestamp))
            .font(AppFont.caption)
            .foregroundStyle(palette.foregroundMuted)
        }
        .padding(.leading, -8)
      }
    }
  }
}

private struct SystemNote: View {
  let text: String
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      Hairline()
      Text(text.replacingOccurrences(of: "\n", with: " "))
        .font(AppFont.caption)
        .foregroundStyle(palette.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Hairline()
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Work

/// "Worked for 2m ›" and, opened, the steps behind it. A running turn shows its latest steps.
private struct WorkLogView: View {
  let group: WorkLog
  let isExpanded: Bool
  let toggle: () -> Void
  let inspect: (ToolCall) -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: toggle) {
        HStack(spacing: 5) {
          // A running turn's progress is told by the working row at the foot of the transcript.
          Text(group.label)
            .font(AppFont.label)
            .foregroundStyle(group.hasError ? palette.dangerForeground : palette.foregroundMuted)
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.chevron)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(group.label)
      .accessibilityValue(isExpanded ? "expanded" : "collapsed")
      .accessibilityIdentifier("transcript.work")

      let shown = visible
      if !shown.isEmpty {
        VStack(alignment: .leading, spacing: 9) {
          if hiddenCount > 0 {
            Text(hiddenCount == 1 ? "1 earlier step" : "\(hiddenCount) earlier steps")
              .font(AppFont.caption)
              .foregroundStyle(palette.foregroundMuted)
          }
          ForEach(shown) { item in
            if let tool = item.tool {
              ToolRow(tool: tool) { inspect(tool) }
            } else if !item.text.isEmpty {
              MarkdownView(text: item.text, style: .note)
            } else if !item.reasoning.isEmpty {
              Text(item.reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.custom("DMSans-Italic", size: 13, relativeTo: .footnote))
                .foregroundStyle(palette.foregroundMuted)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(.leading, 2)
      }
    }
  }

  private static let liveTail = 3

  private var visible: [TranscriptItem] {
    if isExpanded { return group.items }
    return group.isLive ? Array(group.items.suffix(Self.liveTail)) : []
  }

  private var hiddenCount: Int {
    isExpanded || !group.isLive ? 0 : max(0, group.items.count - Self.liveTail)
  }
}

private struct ToolRow: View {
  let tool: ToolCall
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: ToolPresentation.symbol(for: tool.name))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(tool.isError ? palette.dangerForeground : palette.iconMuted)
          .frame(width: 16)
        Text(ToolPresentation.title(for: tool.name))
          .font(AppFont.labelMedium)
          .foregroundStyle(palette.foregroundSecondary)
          .layoutPriority(1)
        Text(detail)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 6)
        trailing
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(ToolPresentation.title(for: tool.name)) \(detail)")
  }

  private var detail: String {
    let text = tool.context.isEmpty ? tool.summary : tool.context
    return text.replacingOccurrences(of: "\n", with: " ")
  }

  @ViewBuilder
  private var trailing: some View {
    if !tool.isDone {
      ProgressView().controlSize(.mini)
    } else if tool.isError {
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 12))
        .foregroundStyle(palette.dangerForeground)
    } else if let duration = tool.duration, duration >= 0.1 {
      Text(duration < 10 ? String(format: "%.1fs", duration) : "\(Int(duration))s")
        .font(AppFont.mono(11))
        .foregroundStyle(palette.foregroundMuted)
    }
  }
}

enum ToolPresentation {
  static func symbol(for name: String) -> String {
    switch name {
    case "terminal", "shell", "process", "process_manage": return "apple.terminal"
    case "read_file": return "doc.text"
    case "write_file": return "doc.badge.plus"
    case "patch": return "pencil.line"
    case "search_files": return "magnifyingglass"
    case "web_search": return "globe"
    case "web_extract": return "doc.richtext"
    case "execute_code": return "chevron.left.forwardslash.chevron.right"
    case "delegate_task": return "person.2"
    case "clarify": return "questionmark.bubble"
    case "vision_analyze": return "eye"
    case "text_to_speech": return "waveform"
    case "todo", "todo_list": return "checklist"
    case "cronjob", "cronjob_manage": return "clock"
    default:
      if name.hasPrefix("browser") { return "safari" }
      if name.contains("memory") || name.contains("notes") { return "brain" }
      if name.contains("skill") { return "book.closed" }
      if name.hasPrefix("mcp") { return "puzzlepiece.extension" }
      return "wrench.and.screwdriver"
    }
  }

  /// `read_file` reads better as "Read file".
  static func title(for name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " ")
    let words = cleaned.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
    guard let first = words.first else { return name }
    return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
  }
}

/// Arguments and result of one tool call.
private struct ToolDetailSheet: View {
  let tool: ToolCall
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if !tool.summary.isEmpty {
            Text(tool.summary)
              .font(AppFont.footnote)
              .foregroundStyle(tool.isError ? palette.dangerForeground : palette.foregroundSecondary)
          }
          if let args = argumentsText { section("Input", args) }
          if !tool.result.isEmpty { section("Output", ToolDetailSheet.clip(tool.result)) }
          if !tool.inlineDiff.isEmpty { section("Diff", ToolDetailSheet.clip(ToolDetailSheet.stripANSI(tool.inlineDiff))) }
          if argumentsText == nil, tool.result.isEmpty, tool.inlineDiff.isEmpty {
            Text(tool.isDone ? "Nothing was recorded for this step." : "Still running.")
              .font(AppFont.footnote)
              .foregroundStyle(palette.foregroundMuted)
          }
        }
        .padding(Metrics.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(palette.sheetSolid)
      .navigationTitle(ToolPresentation.title(for: tool.name))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var argumentsText: String? {
    let parsed = tool.args.parsedIfJSONString
    guard let fields = parsed.object, !fields.isEmpty else { return parsed.string.flatMap { $0.isEmpty ? nil : $0 } }
    return fields.keys.sorted().map { key in
      let value = fields[key] ?? .null
      return "\(key): \(value.scalarText ?? value.text())"
    }.joined(separator: "\n")
  }

  private func section(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title.uppercased())
          .font(AppFont.sans(11, .semibold))
          .kerning(0.6)
          .foregroundStyle(palette.foregroundMuted)
        Spacer()
        CopyButton(text: body, size: 12)
      }
      Text(body)
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

  /// Tool output can run to megabytes; the sheet shows the head and says so.
  static func clip(_ text: String, limit: Int = 12_000) -> String {
    text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)" : text
  }

  static func stripANSI(_ text: String) -> String {
    text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
  }
}

// MARK: - Status and empty states

/// Muted text with a highlight sweeping across it, for work in progress.
struct ShimmerText: View {
  let text: String
  var font: Font = AppFont.label
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: CGFloat = -1

  var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(palette.foregroundSecondary)
      .overlay {
        if !reduceMotion {
          GeometryReader { proxy in
            LinearGradient(colors: [.clear, palette.foreground.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: proxy.size.width * 0.6)
              .offset(x: phase * proxy.size.width)
          }
          .mask(Text(text).font(font))
          .allowsHitTesting(false)
        }
      }
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.2 }
      }
  }
}

private struct TranscriptPlaceholder: View {
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous)
        .fill(palette.groupedCard)
        .frame(width: 220, height: 44)
        .frame(maxWidth: .infinity, alignment: .trailing)
      ForEach([260.0, 300.0, 180.0], id: \.self) { width in
        RoundedRectangle(cornerRadius: 5).fill(palette.groupedCard).frame(width: width, height: 13)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 20)
    .accessibilityLabel("Loading")
  }
}

private struct EmptyChat: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 12) {
      AvatarView(profile: profile, size: 52)
      Text(app.title(forProfile: profile))
        .font(AppFont.title)
        .foregroundStyle(palette.foreground)
      Text("Ask anything. The work runs on your Mac.")
        .font(AppFont.footnote)
        .foregroundStyle(palette.foregroundMuted)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 140)
  }
}
