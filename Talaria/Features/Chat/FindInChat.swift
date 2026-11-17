import HermesKit
import SwiftUI

/// Find in chat: a word, how many messages it appears in, and stepping through them.
///
/// The rows on the phone are searched as they change. The rest of the chat is read from the Mac
/// once, into a list of its own, so what is on screen and where the next older page starts stay
/// as they are. Stepping to a match in that list loads the older pages down to it, as scrolling up
/// would, then the transcript scrolls there (`TranscriptView.reveal`).
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

  /// The searchable rows read from the Mac, older than any the phone held when Find opened.
  private var olderEntries: [ChatFind.Entry]?
  @ObservationIgnored private var index = ChatFind.Index()
  @ObservationIgnored private var readTask: Task<Void, Never>?
  @ObservationIgnored private var stepTask: Task<Void, Never>?
  @ObservationIgnored private var typingTask: Task<Void, Never>?
  @ObservationIgnored private var serial = 0
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
  }

  // MARK: Matches

  /// Every match, newest first: those on the phone, then those only on the Mac.
  var hits: [ChatFind.Hit] {
    let rows = chat.rows
    let onPhone = ChatFind.hits(in: index.entries(rows), query: query)
    guard let olderEntries else { return onPhone }
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

  private var hasQuery: Bool { !ChatFind.fold(query).isEmpty }

  private func position(in hits: [ChatFind.Hit]) -> Int? {
    guard let current else { return nil }
    return hits.firstIndex { $0.isSame(as: current) }
  }

  /// "3 of 12", "Searching...", "No matches", or nothing before a word is typed.
  var status: String {
    guard hasQuery else { return "" }
    if isReadingOlder { return "Searching..." }
    let hits = hits
    if hits.isEmpty { return "No matches" }
    if let at = position(in: hits) { return "\(at + 1) of \(hits.count)" }
    return hits.count == 1 ? "1 match" : "\(hits.count) matches"
  }

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

  /// Done: nothing more is read or loaded for this search.
  func close() {
    readTask?.cancel()
    stepTask?.cancel()
    typingTask?.cancel()
  }

  private func go(to hit: ChatFind.Hit) {
    current = hit
    stepTask?.cancel()
    stepTask = nil
    if let row = rowOnPhone(hit) {
      isLoadingTarget = false
      show(row)
      return
    }
    isLoadingTarget = true
    stepTask = Task { [weak self] in
      guard let self else { return }
      _ = await chat.loadOlder(
        until: { Task.isCancelled || self.rowOnPhone(hit) != nil },
        untilStill: { while self.isScrolling, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) } })
      guard !Task.isCancelled else { return }
      isLoadingTarget = false
      guard current?.isSame(as: hit) == true, let row = rowOnPhone(hit) else { return }
      show(row)
    }
  }

  /// The match's row among the rows on the phone, once its page is there.
  private func rowOnPhone(_ hit: ChatFind.Hit) -> UUID? {
    let rows = chat.rows
    if rows.contains(where: { $0.id == hit.row }) { return hit.row }
    // Rows before the first message from the person are only placed once the start is held.
    guard hit.place.turn != nil || !chat.hasOlder else { return nil }
    return index.entries(rows).first { $0.place == hit.place }?.row
  }

  private func show(_ row: UUID) {
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
    if olderEntries == nil, readTask == nil, chat.hasOlder { readOlder() }
    // Once typing pauses, the newest match shows.
    typingTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self, current == nil, let first = hits.first else { return }
      go(to: first)
    }
  }

  private func readOlder() {
    isReadingOlder = true
    readTask = Task { [weak self] in
      guard let self else { return }
      do {
        let rows = try await chat.readOlderForFind()
        guard !Task.isCancelled else { return }
        olderEntries = ChatFind.entries(rows)
      } catch {
        if !Task.isCancelled { report("Could not search older messages: \(error.localizedDescription)") }
      }
      isReadingOlder = false
      // Nothing matched on the phone while it read: show the newest match found on the Mac.
      if !Task.isCancelled, current == nil, hasQuery, let first = hits.first { go(to: first) }
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
          .accessibilityIdentifier("find.count")
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
