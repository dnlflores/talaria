import HermesKit
import SwiftUI

/// The scrolling conversation. It follows the newest message while you are at the bottom
/// and leaves you alone once you scroll up.
///
/// A chat opens on its newest messages. Scrolling within a screen of the top brings in more:
/// first rows already read (the rows are laid out eagerly, since a lazy stack with a bottom
/// anchor mis-places its content when a row changes height, so only the newest `visibleLimit`
/// show at first), then older pages from the Mac. What was on screen stays where it was.
struct TranscriptView: View {
  let chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var position = ScrollPosition(edge: .bottom)
  /// True while the view should keep the newest content in sight.
  @State private var isFollowing = true
  /// Button visibility is geometric, not the intent to auto-follow new content.
  @State private var showsJumpToLatest = false
  @State private var isUserScrolling = false
  @State private var visibleLimit = TranscriptView.pageSize
  @State private var expanded: Set<UUID> = []
  @State private var inspected: ToolCall?
  @State private var tracker = ScrollTracker()

  private static let pageSize = 40
  /// This close to the end counts as being at the bottom, where the view follows.
  private static let followTolerance: CGFloat = 60

  /// Where the scroll stands, read on every frame of a scroll.
  private struct Position: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var container: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat

    /// How far the end of the transcript is below what shows above the composer.
    var toBottom: CGFloat { content + bottomInset - offset - container }

    /// The content or the room it shows in changed: new text, the composer or the keyboard.
    func resized(from old: Position) -> Bool {
      content != old.content || container != old.container
        || bottomInset != old.bottomInset || topInset != old.topInset
    }
  }

  /// Scroll bookkeeping kept out of SwiftUI's state: it changes on every frame of a scroll, and a
  /// state change there would lay the whole transcript out again each frame.
  private final class ScrollTracker {
    /// The top row as last laid out, and as last seen by the scroll handler.
    var firstRow: UUID?
    var settledFirstRow: UUID?
    /// The person has scrolled this transcript; until then the top is not reached by accident
    /// while the view settles at the bottom.
    var hasScrolled = false
    /// Rows just added above finish laying out over a few frames; their growth is offset too.
    var settlingUntil = Date.distantPast
    /// Content grew while following during a gesture, which was left alone until it ends.
    var grewDuringGesture = false
  }

  var body: some View {
    let rows = chat.rows
    let hidden = windowStart(rows)
    let shown = rows[hidden...]
    let _ = tracker.firstRow = shown.first?.id
    ScrollView {
      // No implicit animations in here: an animated update moves every row it touches over its
      // duration, while the scroll that keeps the end in sight jumps, so rows trail behind.
      VStack(alignment: .leading, spacing: 18) {
        if chat.isLoading {
          TranscriptPlaceholder()
        } else if chat.isEmpty {
          EmptyChat(profile: chat.profile)
        } else {
          if hidden > 0 || chat.hasOlder {
            EarlierRow(isLoading: chat.isLoadingOlder) { loadEarlier() }
          }
          ForEach(shown) { row in
            rowView(row).id(row.id)
          }
          if let activity = chat.activity {
            WorkingRow(activity: activity, startedAt: chat.turnStartedAt)
          }
        }
      }
      .padding(.horizontal, Metrics.screenPadding)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("transcript.scroll")
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .scrollPosition($position)
    .scrollDismissesKeyboard(.interactively)
    .onScrollPhaseChange { _, phase in
      isUserScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
      if phase == .interacting || phase == .tracking { tracker.hasScrolled = true }
      // Growth during the gesture was left alone; catch up once the scroll is still. A plain
      // drag that ends near the end is not moved afterwards.
      if phase == .idle, tracker.grewDuringGesture {
        tracker.grewDuringGesture = false
        if isFollowing { withAnimation(.snappy(duration: 0.25)) { position.scrollTo(edge: .bottom) } }
      }
    }
    .onScrollGeometryChange(for: Position.self) { geometry in
      Position(
        offset: geometry.contentOffset.y, content: geometry.contentSize.height,
        container: geometry.containerSize.height, topInset: geometry.contentInsets.top,
        bottomInset: geometry.contentInsets.bottom)
    } action: { old, new in
      // This report is from before rows added above were offset; the next one is from after.
      if keepPlace(old: old, new: new) { return }
      follow(old: old, new: new)
      // Within a screen of the top, read on; a transcript shorter than the screen fills it.
      let nearTop = new.offset + new.topInset < new.container
      if nearTop, new.content < new.container || tracker.hasScrolled {
        loadEarlier()
      }
    }
    .onScrollGeometryChange(for: Bool.self) { geometry in
      let distanceToBottom = geometry.contentSize.height + geometry.contentInsets.bottom
        - geometry.contentOffset.y - geometry.containerSize.height
      let viewportHeight = geometry.visibleRect.height
      return viewportHeight > 0 && distanceToBottom >= viewportHeight
    } action: { _, shouldShow in
      showsJumpToLatest = shouldShow
    }
    .onChange(of: chat.scrollToEnd) {
      isFollowing = true
      withAnimation(.snappy(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }
    .overlay(alignment: .bottom) {
      // The button's animation stays on the button: on the scroll view it would also animate
      // whatever the transcript did in the same update.
      ZStack {
        if showsJumpToLatest, !chat.isEmpty, !chat.isLoading {
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
      .animation(.snappy(duration: 0.2), value: showsJumpToLatest)
    }
    .sheet(item: $inspected) { tool in
      ToolDetailSheet(tool: tool)
        .presentationDetents([.medium, .large])
    }
  }

  /// Following starts at the bottom and stops only when the person scrolls up away from it.
  /// Content growing under a view that is not moving, or arriving mid-gesture, never stops it.
  /// While following, any resize (new text, the composer, the keyboard) scrolls to the end.
  private func follow(old: Position, new: Position) {
    let atBottom = new.toBottom <= Self.followTolerance
    let wasAtBottom = old.toBottom <= Self.followTolerance
    if isUserScrolling {
      if atBottom {
        if !isFollowing { isFollowing = true }
      } else if new.offset < old.offset - 0.5, isFollowing {
        isFollowing = false
      }
    } else if atBottom, !isFollowing, !wasAtBottom || new.content < old.content {
      // Back at the end without a gesture: a work log closed, or the content shrank. Opening one
      // at the end grows the content, and stays a reading of it.
      isFollowing = true
    }
    // Even when already at the end, or shorter than the screen: until a first `scrollTo`, SwiftUI
    // re-applied the initial bottom anchor on later size changes, so opening a work log or
    // Load more in a short chat pulled the reader down.
    if isFollowing, new.resized(from: old) {
      if isUserScrolling { tracker.grewDuringGesture = true } else { position.scrollTo(edge: .bottom) }
    }
  }

  /// Where the rows on screen start. Following, they are the newest `visibleLimit`. Reading
  /// back, the top row stays as rows arrive below: sliding it out from under the reader moved
  /// everything on screen up by its height. It moves up only to show more.
  private func windowStart(_ rows: [TranscriptRow]) -> Int {
    let newest = max(0, rows.count - visibleLimit)
    guard !isFollowing, let first = tracker.firstRow,
      let index = rows.firstIndex(where: { $0.id == first })
    else { return newest }
    return min(index, newest)
  }

  /// Shows more above: rows already read first, else the next older page from the Mac.
  private func loadEarlier() {
    guard !chat.isLoading, !chat.isLoadingOlder else { return }
    let hidden = windowStart(chat.rows)
    if hidden > 0 {
      visibleLimit = chat.rows.count - hidden + Self.pageSize
    } else if chat.hasOlder {
      Task {
        await chat.loadOlder {
          while isUserScrolling { try? await Task.sleep(for: .milliseconds(50)) }
        }
        // Everything read is shown: the page just read, and the row it may have merged into.
        visibleLimit = max(visibleLimit, chat.rows.count)
      }
    }
  }

  /// Rows added above push what is on screen down by their height; scrolling down by the same
  /// amount keeps it in place. Rows count as added above when the top row changed and the
  /// content grew.
  @discardableResult
  private func keepPlace(old: Position, new: Position) -> Bool {
    let grew = new.content - old.content
    if let first = tracker.firstRow, first != tracker.settledFirstRow {
      let isFirstLayout = tracker.settledFirstRow == nil
      tracker.settledFirstRow = first
      guard !isFirstLayout, !isFollowing, grew > 0 else { return false }
      tracker.settlingUntil = Date().addingTimeInterval(0.6)
      scroll(toOffset: old.offset + grew, inset: new.topInset)
      return true
    } else if grew != 0, Date() < tracker.settlingUntil, !isFollowing, !isUserScrolling {
      scroll(toOffset: old.offset + grew, inset: new.topInset)
      return true
    }
    return false
  }

  /// `ScrollPosition` counts from the top of the content below the bars; `contentOffset`, which
  /// the scroll geometry reports, counts from under them.
  private func scroll(toOffset offset: CGFloat, inset: CGFloat) {
    position.scrollTo(y: offset + inset)
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
      UserBubble(item: item, profile: chat.profile, storedID: chat.storedID)
    case .answer(let item):
      AnswerView(item: item)
    case .commentary(let item):
      CommentaryView(item: item)
    case .work(let group):
      WorkLogView(
        group: group, isExpanded: expanded.contains(group.id),
        toggle: { toggle(group.id) },
        inspect: { inspected = $0 },
        willReveal: { isFollowing = false })
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

/// The top of a transcript that goes back further: a spinner while the next page is read, else a
/// button that reads it (scrolling up does the same).
private struct EarlierRow: View {
  let isLoading: Bool
  let load: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Group {
      if isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading earlier messages")
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundMuted)
        }
      } else {
        Button(action: load) {
          Text("Earlier messages")
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 36)
    .accessibilityIdentifier("transcript.earlier")
  }
}

// MARK: - Messages

private struct UserBubble: View {
  let item: TranscriptItem
  let profile: String
  let storedID: String
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .trailing, spacing: 3) {
      if !pictures.isEmpty {
        PictureGallery(pictures: pictures, profile: profile, storedID: storedID, alignment: .trailing)
          .opacity(item.isPending ? 0.6 : 1)
          .padding(.bottom, item.text.isEmpty ? 0 : 3)
      }
      let files = item.attachments.filter { $0.kind == .file || $0.thumbnail == nil }
      if !files.isEmpty {
        HStack(spacing: 6) {
          ForEach(files) { attachment in
            AttachmentThumbnail(name: attachment.name, image: nil, isImage: attachment.kind == .image)
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

  /// Photos picked on this phone show from their local copy until the Mac's copy replaces them.
  private var pictures: [ChatPicture] {
    let local = item.attachments.compactMap { attachment -> ChatPicture? in
      guard attachment.kind == .image, let data = attachment.thumbnail, let image = UIImage(data: data) else { return nil }
      return .local(id: attachment.id, image: image, name: attachment.name)
    }
    return local + item.images.map { .remote(path: $0) }
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

/// Public progress text stays outside tool logs, distinct from both thinking and the answer.
private struct CommentaryView: View {
  let item: TranscriptItem

  var body: some View {
    MarkdownView(text: FileExtraction.hidingMediaLines(item.text), style: .note)
      .textSelection(.enabled)
      .accessibilityIdentifier("transcript.commentary")
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
  var willReveal: () -> Void = {}
  @Environment(\.palette) private var palette
  @State private var toolLimit = 20

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
            } else {
              ForEach(Array(item.workContent.enumerated()), id: \.offset) { _, block in
                switch block {
                case .reasoning(let text):
                  VStack(alignment: .leading, spacing: 4) {
                    Label("Thinking", systemImage: "sparkle")
                      .font(AppFont.labelMedium)
                    Text((try? AttributedString(markdown: text,
                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                      .font(.custom("DMSans-Italic", size: 13, relativeTo: .footnote))
                      .lineLimit(isExpanded ? nil : 3)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  .foregroundStyle(palette.transcriptReasoning)
                  .padding(.leading, 12)
                  .padding(.vertical, 3)
                  .overlay(alignment: .leading) {
                    Rectangle().fill(palette.transcriptReasoning.opacity(0.5)).frame(width: 2)
                  }
                case .commentary(let text):
                  MarkdownView(text: text, style: .note)
                }
              }
            }
          }
        }
        .padding(.leading, 2)
      }
      if isExpanded, remainingTools > 0 {
        Button {
          willReveal()
          toolLimit += 20
        } label: {
          Text("Load \(min(20, remainingTools)) more tool calls (\(remainingTools) remaining)")
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.primaryText)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.tools.more")
      }
    }
    .onChange(of: isExpanded) { _, open in
      if !open { toolLimit = 20 }
    }
  }

  private var remainingTools: Int { max(0, group.toolCount - toolLimit) }
  private static let liveTail = 3

  private var visible: [TranscriptItem] {
    if isExpanded { return group.page(toolLimit: toolLimit) }
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
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: ToolPresentation.symbol(for: tool.name))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(tool.isError ? palette.dangerForeground : palette.transcriptTool)
          .frame(width: 26, height: 26)
          .background((tool.isError ? palette.dangerForeground : palette.transcriptTool).opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
        VStack(alignment: .leading, spacing: 2) {
          Text(ToolPresentation.title(for: tool.name))
            .font(AppFont.labelMedium)
            .foregroundStyle(tool.isError ? palette.dangerForeground : palette.transcriptTool)
          if !detail.isEmpty {
            Text(detail)
              .font(AppFont.mono(12))
              .foregroundStyle(palette.foregroundSecondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer(minLength: 6)
        trailing
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(ToolPresentation.title(for: tool.name)) \(detail)")
    .accessibilityValue(tool.isError ? "Failed" : !tool.isDone ? "Running" : tool.duration.map { "Completed in \(WorkLog.duration($0))" } ?? "Completed")
    .accessibilityIdentifier("transcript.tool.\(tool.callID)")
  }

  private var detail: String { tool.preview }

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

  /// One sweep across the text, in seconds.
  private static let sweep = 1.4

  var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(palette.foregroundSecondary)
      .overlay {
        if !reduceMotion {
          // Driven by the clock, like `WorkingDots`: a repeating animation started on appear also
          // animates any move of the row made in the same update, and the text drifts off its row.
          TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: Self.sweep) / Self.sweep
            GeometryReader { proxy in
              LinearGradient(colors: [.clear, palette.foreground.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.6)
                .offset(x: (-1 + 2.2 * progress) * proxy.size.width)
            }
          }
          .mask(Text(text).font(font))
          .allowsHitTesting(false)
        }
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

#if DEBUG
/// Reuses the production work log and inspector, but no ChatModel, credentials or network.
struct TranscriptPreviewFixture: View {
  @State private var expanded = !ProcessInfo.processInfo.arguments.contains("--many-tools")
    && !ProcessInfo.processInfo.arguments.contains("--provider-display")
  @State private var inspected: ToolCall?
  @Environment(\.palette) private var palette

  private static let rows: [TranscriptRow] = {
    if ProcessInfo.processInfo.arguments.contains("--provider-display") {
      let stored: [JSONValue] = [
        ["role": "assistant", "content": "", "reasoning": "Private GPT reasoning plus flattened public words.",
         "display_reasoning": "Private GPT reasoning.",
         "display_commentary": ["GPT: I found the cause. This progress message stays readable outside the tools."],
         "tool_calls": [["id": "provider-gpt", "function": ["name": "read_file", "arguments": "{}"]]]],
        ["role": "tool", "tool_call_id": "provider-gpt", "content": "Checked."],
        ["role": "user", "display_kind": "process_complete", "content": "[IMPORTANT: Background process internal plumbing]"],
        ["role": "assistant", "content": "GPT: The fix is ready."],
        ["role": "user", "content": "Compare the next provider."],
        ["role": "assistant", "content": "Claude: I found the cause. This progress message stays readable outside the tools.",
         "reasoning": "Private Claude reasoning.",
         "tool_calls": [["id": "provider-claude", "function": ["name": "read_file", "arguments": "{}"]]]],
        ["role": "tool", "tool_call_id": "provider-claude", "content": "Checked."],
        ["role": "user", "display_kind": "async_delegation_complete", "content": "[ASYNC DELEGATION BATCH COMPLETE internal plumbing]"],
        ["role": "assistant", "content": "Claude: The fix is ready."],
      ]
      return TranscriptLayout.rows(for: TranscriptItem.items(fromStoredRows: stored), isStreaming: false)
    }
    if ProcessInfo.processInfo.arguments.contains("--many-tools") {
      let calls = (1...45).map { index -> TranscriptItem in
        var call = ToolCall(callID: "page-\(index)", name: "read_file",
          args: ["path": .string("file-\(index).swift")], isDone: true)
        call.result = "Recorded output for call \(index)."
        return .tool(call)
      }
      return TranscriptLayout.rows(for: [
        .user("Inspect the files.", timestamp: 1),
        TranscriptItem(kind: .assistant, text: "I will inspect the files."),
      ] + calls + [
        TranscriptItem(kind: .assistant, text: "The checks are complete."),
        .tool(ToolCall(callID: "page-check", name: "terminal", isDone: true)),
        TranscriptItem(kind: .assistant, text: "All 45 files checked."),
      ], isStreaming: false)
    }
    var note = TranscriptItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .assistant,
      text: "I'll inspect the **file** before making a change.")
    note.reasoning = "**A small, focused change** will keep the transcript easy to scan.\n\n**Check one change at a time.**"
    var read = ToolCall(callID: "preview-read", name: "read_file", args: ["path": "Talaria/Theme/Theme.swift"], isDone: true)
    read.duration = 0.4
    read.result = "extension Palette { /* semantic transcript colors */ }"
    var failed = ToolCall(callID: "preview-error", name: "terminal", context: "swift test — retry needed", isDone: true)
    failed.isError = true
    failed.result = "The first test caught the missing presentation behavior."
    let running = ToolCall(callID: "preview-running", name: "terminal", context: "Checking the focused tests")
    return TranscriptLayout.rows(for: [note, .tool(read),
      TranscriptItem(kind: .assistant, text: "The tool output is separate from my explanation."),
      .tool(failed), .tool(running),
      TranscriptItem(kind: .assistant, text: "Tools, thinking and explanations now have a clear hierarchy.")], isStreaming: false)
  }()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(Self.rows) { row in
            switch row {
            case .work(let group):
              WorkLogView(group: group, isExpanded: expanded, toggle: { expanded.toggle() }, inspect: { inspected = $0 })
            case .answer(let item):
              AnswerView(item: item)
            case .commentary(let item):
              CommentaryView(item: item)
            default: EmptyView()
            }
          }
        }
        .padding(Metrics.screenPadding)
      }
      .background(palette.screen)
      .navigationTitle("Transcript preview")
      .navigationBarTitleDisplayMode(.inline)
      .sheet(item: $inspected) { tool in
        ToolDetailSheet(tool: tool).presentationDetents([.medium, .large])
      }
    }
  }
}
#endif
