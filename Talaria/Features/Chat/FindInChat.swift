import HermesKit
import SwiftUI

/// Find in chat: a word, how many messages it appears in, and stepping through them.
///
/// The rows on the phone are searched as they change. The rest of the chat is read from the Mac
/// into a list of its own, so what is on screen and where the next older page starts stay as they
/// are. That list is read again whenever the chat's history is started over (a reattach that does
/// not line up, a rewind: `ChatModel.historyEpoch`), and after a read that failed. Stepping to a
/// match in it loads the older pages down to it, as scrolling up would, then the transcript
/// scrolls there (`TranscriptView.reveal`).
///
/// Matches run newest first: "1 of 12" is the newest, and each step up goes one older.
@MainActor @Observable
final class ChatFinder {
  struct Reveal: Equatable {
    let row: UUID
    let serial: Int
  }

  struct Highlight: Equatable {
    let row: UUID
    let start: Date
    let serial: Int
  }

  let chat: ChatModel
  var query = "" {
    didSet { if query != oldValue { queryChanged() } }
  }
  /// The rest of the chat is being read from the Mac.
  private(set) var isReadingOlder = false
  /// The rest of the chat could not be read: the matches are only those on the phone until a
  /// retry (`retryOlder`, or the next word typed) reads it.
  private(set) var olderUnread = false
  /// Older pages are loading on the way to the match shown.
  private(set) var isLoadingTarget = false
  /// The match shown, by identity, so it keeps its place as the lists change.
  private(set) var current: ChatFind.Hit?
  /// The row the transcript should scroll to, bumped on every step.
  private(set) var reveal: Reveal?
  /// The message outlined for a moment after a step.
  private(set) var highlight: Highlight?
  /// Bumped to put the cursor back in the field (Cmd-F again).
  private(set) var focusRequest = 0
  /// The transcript is being scrolled by hand; pages wait for it to stop.
  @ObservationIgnored var isScrolling = false

  /// The searchable rows read from the Mac, older than any the phone held when they were read.
  private var olderEntries: [ChatFind.Entry]?
  /// The `ChatModel.historyEpoch` those rows were read for; for any other they are not counted.
  @ObservationIgnored private var olderEpoch = -1
  @ObservationIgnored private var index = ChatFind.Index()
  @ObservationIgnored private var readTask: Task<Void, Never>?
  /// Bumped per read, so only the newest one changes anything when it ends.
  @ObservationIgnored private var readSerial = 0
  @ObservationIgnored private var stepTask: Task<Void, Never>?
  @ObservationIgnored private var typingTask: Task<Void, Never>?
  @ObservationIgnored private var serial = 0
  @ObservationIgnored private var isClosed = false
  private let report: (String) -> Void

  /// How long the outline holds, then fades. Screenshot runs hold it longer
  /// (`TALARIA_UITEST_HIGHLIGHT_HOLD=<seconds>`).
  static let highlightHold: Double = {
    #if DEBUG
      if let hold = ProcessInfo.processInfo.environment["TALARIA_UITEST_HIGHLIGHT_HOLD"].flatMap(Double.init) { return hold }
    #endif
    return 1.4
  }()
  static let highlightFade = 0.8

  init(chat: ChatModel, report: @escaping (String) -> Void) {
    self.chat = chat
    self.report = report
    watchHistory()
  }

  // MARK: Matches

  /// Every match, newest first: those on the phone, then those only on the Mac.
  var hits: [ChatFind.Hit] {
    let rows = chat.rows
    let onPhone = ChatFind.hits(in: index.entries(rows, holdsStart: !chat.hasOlder), query: query)
    // Rows read for a history since started over are not what is older than the window now.
    guard let olderEntries, olderEpoch == chat.historyEpoch else { return onPhone }
    // Pages loaded since the read hold some of those rows now: they count once, on the phone.
    let heldTurns = Set(rows.compactMap { row -> Int? in
      if case .user(let item) = row { return item.rowID }
      return nil
    })
    let heldStart = !chat.hasOlder
    let older = ChatFind.hits(in: olderEntries, query: query).filter { hit in
      if let turn = hit.place.turn { return !heldTurns.contains(turn) }
      return !heldStart
    }
    return onPhone + older
  }

  var hasQuery: Bool { !ChatFind.fold(query).isEmpty }

  private func position(in hits: [ChatFind.Hit]) -> Int? {
    guard let current else { return nil }
    return hits.firstIndex { $0.isSame(as: current) }
  }

  /// "3 of 12", "Searching...", "No matches", or nothing before a word is typed. When the rest of
  /// the chat could not be read, no match on the phone says so rather than "No matches".
  var status: String {
    guard hasQuery else { return "" }
    if isReadingOlder { return "Searching..." }
    let hits = hits
    if hits.isEmpty { return olderUnread ? "Older not searched" : "No matches" }
    if let at = position(in: hits) { return "\(at + 1) of \(hits.count)" }
    return hits.count == 1 ? "1 match" : "\(hits.count) matches"
  }

  /// The older messages could not be read for this word and can be tried again.
  var canRetry: Bool { hasQuery && olderUnread && !isReadingOlder }

  var canGoOlder: Bool {
    let hits = hits
    guard let at = position(in: hits) else { return !hits.isEmpty }
    return at < hits.count - 1
  }

  var canGoNewer: Bool {
    guard let at = position(in: hits) else { return false }
    return at > 0
  }

  // MARK: Stepping

  /// The up arrow: one match older.
  func older() {
    let hits = hits
    guard !hits.isEmpty else { return }
    let at = position(in: hits).map { $0 + 1 } ?? 0
    if hits.indices.contains(at) { go(to: hits[at]) }
  }

  /// The down arrow: one match newer.
  func newer() {
    let hits = hits
    guard let at = position(in: hits), at > 0 else { return }
    go(to: hits[at - 1])
  }

  /// Return in the field: the next match in the count, back to the newest after the oldest.
  func next() {
    let hits = hits
    guard !hits.isEmpty else { return }
    let at = position(in: hits).map { $0 + 1 } ?? 0
    go(to: hits[hits.indices.contains(at) ? at : 0])
  }

  func focus() { focusRequest += 1 }

  /// Reads the older messages again after a read that failed.
  func retryOlder() {
    guard canRetry, chat.hasOlder else { return }
    readOlder()
  }

  /// Done: nothing more is read or loaded for this search, and no page it asked for lands.
  func close() {
    isClosed = true
    readTask?.cancel()
    readTask = nil
    stepTask?.cancel()
    stepTask = nil
    typingTask?.cancel()
    typingTask = nil
    isReadingOlder = false
    isLoadingTarget = false
  }

  private func go(to hit: ChatFind.Hit) {
    current = hit
    stepTask?.cancel()
    stepTask = nil
    if let row = rowOnPhone(hit) {
      isLoadingTarget = false
      show(row, of: hit)
      return
    }
    isLoadingTarget = true
    stepTask = Task { [weak self] in
      guard let self else { return }
      // Cancelled (Done, another step, another word), no further page lands (`loadOlder`).
      _ = await chat.loadOlder(
        until: { self.rowOnPhone(hit) != nil },
        untilStill: { while self.isScrolling, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) } })
      guard !Task.isCancelled else { return }
      isLoadingTarget = false
      guard current?.isSame(as: hit) == true, let row = rowOnPhone(hit) else { return }
      show(row, of: hit)
    }
  }

  /// The match's row among the rows on the phone, once its page is there.
  private func rowOnPhone(_ hit: ChatFind.Hit) -> UUID? {
    let rows = chat.rows
    if rows.contains(where: { $0.id == hit.row }) { return hit.row }
    // Rows before the first message from the person are only placed once the start is held.
    guard hit.place.turn != nil || !chat.hasOlder else { return nil }
    return index.entries(rows, holdsStart: !chat.hasOlder).first { $0.place == hit.place }?.row
  }

  private func show(_ row: UUID, of hit: ChatFind.Hit) {
    // From here on the match is the row on the phone, not the copy the search read.
    current = ChatFind.Hit(row: row, place: hit.place)
    serial += 1
    let serial = serial
    reveal = Reveal(row: row, serial: serial)
    highlight = Highlight(row: row, start: Date(), serial: serial)
    // A plain state change ends the outline once it has faded.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.highlightHold + Self.highlightFade + 0.1))
      if self?.highlight?.serial == serial { self?.highlight = nil }
    }
  }

  // MARK: Typing

  private func queryChanged() {
    current = nil
    stepTask?.cancel()
    stepTask = nil
    isLoadingTarget = false
    typingTask?.cancel()
    guard hasQuery else { return }
    if needsOlderRead { readOlder() }
    // Once typing pauses, the newest match shows.
    typingTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self, current == nil, let first = hits.first else { return }
      go(to: first)
    }
  }

  /// No read is under way and the list read last is missing, failed, or for an older history.
  private var needsOlderRead: Bool {
    chat.hasOlder && readTask == nil && (olderEntries == nil || olderEpoch != chat.historyEpoch)
  }

  // MARK: The rest of the chat

  /// Follows `ChatModel.historyEpoch` for as long as the bar is open.
  private func watchHistory() {
    withObservationTracking {
      _ = chat.historyEpoch
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isClosed else { return }
        self.historyReplaced()
        self.watchHistory()
      }
    }
  }

  /// The history was started over: what was read as older than the window is not any more, and
  /// rows that were on the phone may now be only on the Mac. Read it again, and pick up a step
  /// that was loading pages on the old window.
  private func historyReplaced() {
    guard olderEpoch != chat.historyEpoch || readTask != nil else { return }
    let resume = isLoadingTarget ? current : nil
    stepTask?.cancel()
    stepTask = nil
    isLoadingTarget = false
    readTask?.cancel()
    readTask = nil
    readSerial += 1
    isReadingOlder = false
    olderEntries = nil
    olderUnread = false
    if hasQuery, chat.hasOlder {
      readOlder(then: resume)
    } else if let resume {
      go(to: resume)
    }
  }

  private func readOlder(then resume: ChatFind.Hit? = nil) {
    readTask?.cancel()
    readSerial += 1
    let serial = readSerial
    let epoch = chat.historyEpoch
    isReadingOlder = true
    olderUnread = false
    readTask = Task { [weak self] in
      guard let self else { return }
      let outcome: Result<(rows: [TranscriptRow], reachedStart: Bool), any Error>
      do {
        outcome = .success(try await chat.readOlderForFind())
      } catch {
        outcome = .failure(error)
      }
      // Done, a newer read or a history started over took this one's place.
      guard serial == readSerial, !isClosed, !Task.isCancelled else { return }
      readTask = nil
      isReadingOlder = false
      switch outcome {
      case .success(let read):
        olderEntries = ChatFind.entries(read.rows, holdsStart: read.reachedStart)
        olderEpoch = epoch
      case .failure(let error) where error is CancellationError:
        // The history was started over as it read; the watcher reads it again.
        return
      case .failure(let error):
        olderUnread = true
        report("Could not search older messages: \(error.localizedDescription)")
      }
      guard hasQuery else { return }
      let hits = hits
      if let resume, let again = hits.first(where: { $0.isSame(as: resume) }) {
        go(to: again)
      } else if current == nil, let first = hits.first {
        // Nothing matched on the phone while it read: show the newest match found on the Mac.
        go(to: first)
      }
    }
  }
}

/// The bar under the title: the word, the count, older and newer, Done.
struct FindBar: View {
  @Bindable var finder: ChatFinder
  let done: () -> Void
  @FocusState private var isFocused: Bool
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if finder.isLoadingTarget {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.icon)
        }
      }
      .frame(width: 18)
      TextField("Find in chat", text: $finder.query)
        .font(AppFont.sans(15))
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .onSubmit {
          finder.next()
          isFocused = true
        }
        .accessibilityIdentifier("find.field")
      let status = finder.status
      if !status.isEmpty {
        Text(status)
          .font(AppFont.caption)
          .monospacedDigit()
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .fixedSize()
          .accessibilityLabel(finder.olderUnread ? "\(status), older messages not searched" : status)
          .accessibilityIdentifier("find.count")
      }
      if finder.canRetry {
        // The older messages could not be read: try again.
        Button { finder.retryOlder() } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.foreground)
            .frame(width: 30, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search older messages again")
        .accessibilityIdentifier("find.retry")
      }
      arrow("chevron.up", label: "Older match", id: "find.previous", enabled: finder.canGoOlder) { finder.older() }
      arrow("chevron.down", label: "Newer match", id: "find.next", enabled: finder.canGoNewer) { finder.newer() }
      Button(action: done) {
        Text("Done")
          .font(AppFont.sans(15, .semibold))
          .foregroundStyle(palette.primaryText)
          .padding(.leading, 4)
          .frame(height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("find.done")
    }
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .frame(height: 46)
    .glassCard(radius: 23, fill: palette.card, shadow: false)
    .frame(maxWidth: Metrics.readableWidth)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .onAppear { isFocused = true }
    .onChange(of: finder.focusRequest) { isFocused = true }
  }

  private func arrow(_ symbol: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(enabled ? palette.foreground : palette.iconSubtle)
        .frame(width: 34, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }
}

/// A short tinted outline around the message a step landed on. It fades by the clock, not by an
/// animation transaction, which would also move the transcript's rows (see `TranscriptView`).
struct FindHighlight: View {
  let start: Date
  @Environment(\.palette) private var palette

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
      let age = context.date.timeIntervalSince(start)
      let strength = age < ChatFinder.highlightHold ? 1 : max(0, 1 - (age - ChatFinder.highlightHold) / ChatFinder.highlightFade)
      let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
      shape.fill(palette.primaryText.opacity(0.08 * strength))
        .overlay { shape.strokeBorder(palette.primaryText.opacity(0.8 * strength), lineWidth: 1.5) }
    }
    .padding(.horizontal, -8)
    .padding(.vertical, -4)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
