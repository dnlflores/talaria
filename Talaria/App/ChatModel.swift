import HermesKit
import Observation
import SwiftUI
import UIKit

/// Something picked in the composer, waiting to go out with the next message.
struct ComposerAttachment: Identifiable {
  enum Kind { case image, file }
  enum Status: Equatable { case preparing, ready, failed(String) }

  let id = UUID()
  var kind: Kind
  var name: String
  var mimeType = "application/octet-stream"
  var data: Data?
  var thumbnail: UIImage?
  var status: Status = .preparing

  var isUsable: Bool {
    if case .failed = status { return false }
    return true
  }
}

/// The queue belongs to the conversation, not to one visit to its screen. Both sides of a
/// navigation can briefly be alive while the old model finishes handing messages to the Mac.
@MainActor @Observable
final class ChatQueueState {
  struct PendingAdmission {
    let liveID: String
    let submissionID: String
    let text: String
    let images: [StagedImage]
    let sent: TranscriptItem
  }

  var prompts = PromptQueue<ComposerAttachment>(device: ChatQueueState.deviceKind)
  /// The Mac's queue for this chat as the gateway last listed it: every device's messages.
  var onMacList: [QueuedOnMac] = []
  /// Messages this app handed to the Mac that it is taking back (Edit, Remove, Send now). The
  /// cancellation that brings one back is ours, not a Stop: it must not hold the queue.
  var takingBack: Set<UUID> = []
  /// Other devices' queued messages with an Edit, Remove or Send now on its way to the Mac.
  var actingOn: Set<String> = []
  /// This app's messages handed to the running reply from the Mac's queue (Send now), by
  /// admission, with the bubble shown for each. Until the reply takes one in it can bounce back
  /// to the queue (the reply ended or was stopped first); then it is tracked again.
  @ObservationIgnored var steered: [String: (entry: PromptQueue<ComposerAttachment>.Entry, shown: UUID?)] = [:]
  /// Of those, the ones a Stop came after: if one bounces back it must not run.
  @ObservationIgnored var stoppedSteers: Set<String> = []
  /// A copy of the chat closed with messages it could not hand to the Mac. The next copy holds
  /// them if no reply is running when it opens, rather than sending them on its own.
  @ObservationIgnored var leftWaiting = false
  /// A Try again took its turn back and has not sent the words again yet. Every copy of the chat
  /// is busy until then: a message sent meanwhile waits behind it, and no other Try again starts.
  var isResending = false
  @ObservationIgnored var handoff: Task<Void, Never>?
  @ObservationIgnored var recovery: Task<Void, Never>?
  @ObservationIgnored var cancellation: Task<Void, Never>?
  /// Stop survives navigation and an acknowledgement that has not arrived yet.
  @ObservationIgnored var cancelRequested: Set<UUID> = []
  /// Save the immutable wire payload BEFORE submitting. An unknown outcome cannot be retried
  /// with a new identity or with freshly uploaded attachment paths.
  @ObservationIgnored var pendingAdmissions: [UUID: PendingAdmission] = [:]
  @ObservationIgnored var receipts: [UUID: JSONValue] = [:]
  @ObservationIgnored var sentItems: [UUID: TranscriptItem] = [:]
  @ObservationIgnored var startedAdmissions: Set<String> = []
  /// One rendered prompt per admission, retained so a fresh history read can claim each
  /// matching stored row once instead of letting later equal-text admissions reuse it.
  @ObservationIgnored var renderedAdmissions: [(id: String, sent: TranscriptItem)] = []

  /// Written into every queued message's submission id, so any app reading the Mac's queue can
  /// tell which device it came from. An unfolded iPhone Duo is still an iPhone.
  static var deviceKind: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
  }
}

/// What a closed chat had not sent: words for its composer, picked files, and queued messages,
/// each still its own entry. The next copy of the chat to open takes it back (`AppModel.leaveBehind`).
struct LeftBehind {
  var words = ""
  var attachments: [ComposerAttachment] = []
  var queue = PromptQueue<ComposerAttachment>()
}

/// One open conversation: its transcript, its live session on the Mac, and the composer.
///
/// Chats run in the Hermes gateway on the Mac, the process the desktop app runs them in, so a
/// chat open in both is one live chat: each app sees the other's turns, thinking and questions as
/// they happen, and either can answer a question. Two rules shape the rest:
/// - A chat another Hermes process holds (a terminal running its own agent) is shown read-only
///   and kept fresh by polling; sending continues it as a new version (a branch).
/// - A dropped socket loses its attachment to every chat. On return the chat re-attaches and folds
///   the fresh transcript into what is on screen without rebuilding it.
@MainActor @Observable
final class ChatModel: Identifiable {
  let profile: String
  private(set) var storedID: String
  private(set) var liveID: String?
  /// This app's attachment to the chat on the gateway, let go when the chat closes.
  @ObservationIgnored private var subscriptionID = ""
  let section: SessionSection

  private(set) var state = ChatState() {
    didSet {
      layOut()
      if state.isStreaming != oldValue.isStreaming { streamingChanged() }
    }
  }
  private(set) var rows: [TranscriptRow] = []
  @ObservationIgnored private var fileCache: [String: [FileReference]] = [:]
  private(set) var isLoading = true
  private(set) var loadError: String?
  /// The transcript could be read but the session could not be attached.
  private(set) var isReadOnly = false
  /// Another Hermes process that has this chat open right now.
  private(set) var owner: ChatOwner?
  /// That other process is running a turn here right now (its heartbeat says so). No events
  /// reach this app for it, so the transcript is polled and the activity read from it.
  private(set) var isRunningElsewhere = false {
    didSet { if isRunningElsewhere != oldValue { layOut() } }
  }
  /// A message (or a command, or a Try again) is on its way from this copy of the chat.
  private var sendingHere = false
  /// A message is on its way: from this copy, or a Try again's words from any copy of the chat.
  var isSending: Bool { sendingHere || queueState.isResending }
  private(set) var isBranching = false
  private(set) var uploadStatus = ""
  private(set) var catalog: [ModelProvider]?
  private(set) var catalogError: String?
  /// Older messages are on the Mac beyond what is on screen; they load as the transcript scrolls up.
  private(set) var hasOlder = false
  private(set) var isLoadingOlder = false
  /// Bumped when the view should scroll to the newest message.
  private(set) var scrollToEnd = 0

  var draft: String {
    didSet {
      // While a message is being edited, the draft kept for this chat is the one set aside.
      app?.preferences.setDraft(editing?.stash ?? draft, for: storedID)
      slashDraftChanged()
    }
  }
  /// The newest message being edited in the composer (Edit), until it goes out or is cancelled.
  private(set) var editing: Editing?
  /// The edit is on its way: the words it sends were taken at Send, so the composer holds them
  /// and takes no typing until they have gone out or come back.
  var isSendingEdit: Bool { editing != nil && sendingHere }
  /// Bumped when the composer should take the keyboard (Edit put words in it).
  private(set) var focusComposer = 0
  var attachments: [ComposerAttachment] = []
  var sendWhenReady = false
  /// Messages written while a reply runs. They go out one per turn once it ends, or now on request.
  private let queueState: ChatQueueState
  private(set) var queue: PromptQueue<ComposerAttachment> {
    get { queueState.prompts }
    set { queueState.prompts = newValue }
  }

  /// Messages waiting in the Mac's queue that this app is not tracking: sent from another
  /// device or app (or from this one before it restarted). Shown with where they came from.
  var othersOnMac: [QueuedOnMac] {
    let mine = Set(queue.entries.map(\.submissionID) + queue.onMac.map(\.submissionID)
      + queueState.pendingAdmissions.values.map(\.submissionID) + queueState.steered.values.map(\.entry.submissionID))
    let admitted = Set(queueState.receipts.values.compactMap { $0["admission_id"].string } + queueState.steered.keys)
    return queueState.onMacList.filter { $0.isWaiting && !mine.contains($0.inputID) && !admitted.contains($0.admissionID) }
  }

  /// Something queued to show above the composer, from this device or any other.
  var hasQueue: Bool { queue.isShowing || !othersOnMac.isEmpty }

  /// This device's kind, as other devices' queues name it.
  var deviceKind: String { queue.device ?? ChatQueueState.deviceKind }

  /// What the Mac lets anyone do with one of this app's handed-over messages.
  func macRow(for entry: PromptQueue<ComposerAttachment>.Entry) -> QueuedOnMac? {
    guard let admissionID = queueState.receipts[entry.id]?["admission_id"].string else { return nil }
    return queueState.onMacList.first { $0.admissionID == admissionID }
  }

  func isTakingBack(_ id: UUID) -> Bool { queueState.takingBack.contains(id) }
  func isActing(on row: QueuedOnMac) -> Bool { queueState.actingOn.contains(row.admissionID) }
  #if DEBUG
  var queueStateForTests: ChatQueueState { queueState }
  #endif

  /// One message waiting on the Mac, as the queue panel lists it.
  enum MacQueueRow: Identifiable {
    /// Handed over by this app; still tracked here with its photos and files.
    case mine(PromptQueue<ComposerAttachment>.Entry)
    /// Sent from another device or app.
    case other(QueuedOnMac)

    var id: String {
      switch self {
      case .mine(let entry): entry.id.uuidString
      case .other(let row): row.admissionID
      }
    }
  }

  /// Everything waiting on the Mac, in the order it will run there.
  var macQueue: [MacQueueRow] {
    let rank = Dictionary(queueState.onMacList.enumerated().map { ($1.admissionID, $0) }, uniquingKeysWith: min)
    let steering = Set(queueState.onMacList.filter(\.isSteering).map(\.admissionID))
    let mine = queue.onMac.filter {
      // Being handed to the reply by another device: on its way, not waiting.
      !steering.contains(queueState.receipts[$0.id]?["admission_id"].string ?? "")
    }.map { entry -> (Int, MacQueueRow) in
      // Not listed yet: handed over before anything the list shows.
      let admissionID = queueState.receipts[entry.id]?["admission_id"].string ?? ""
      return (rank[admissionID] ?? -1, .mine(entry))
    }
    let others = othersOnMac.map { (rank[$0.admissionID] ?? Int.max, MacQueueRow.other($0)) }
    return (mine + others).enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
  }
  /// The `/` menu's rows for the `/token` being typed; empty when no menu shows.
  private(set) var slashItems: [SlashCompletion] = []
  @ObservationIgnored private var slashQuery: String?
  @ObservationIgnored private var slashTask: Task<Void, Never>?
  /// Menu rows already read for this chat, by query.
  @ObservationIgnored private var slashCache: [String: [SlashCompletion]] = [:]
  /// The `/command` being worked out or sent, which the queue's hand-off to the Mac waits for.
  @ObservationIgnored private var slashRun: (id: UUID, task: Task<Void, Never>)?
  #if DEBUG
  /// `--slash-preview`: the `/` menu and commands answer from canned data, with no Mac.
  @ObservationIgnored private(set) var isSlashPreview = false
  /// `--scroll-preview`: the offline transcript; Try again plays a canned reply.
  @ObservationIgnored private(set) var isScrollPreview = false
  /// `--older-pages`: the canned stored rows older than what the preview holds, and how many
  /// rows it counts as held.
  @ObservationIgnored private var previewOlderRows: [JSONValue]?
  @ObservationIgnored private var previewHeldRows = 0
  /// `TALARIA_UITEST_HISTORY_FAILS=<n>`: the first `n` reads of those rows fail.
  @ObservationIgnored private var previewFailuresLeft = 0
  #endif

  private weak var app: AppModel?
  private var prepared: LiveSession?
  private var hasOpened = false
  @ObservationIgnored private var openingEvents: [GatewayEvent] = []
  @ObservationIgnored private var isReplayingOpeningEvents = false
  @ObservationIgnored private var claimedQueueUserIDs: Set<UUID> = []
  private(set) var isClosed = false
  /// Queued messages taken back from a closed copy of this chat, before it opened: they are held
  /// if no reply is running once it has opened, rather than sent on their own.
  @ObservationIgnored private var holdsTakenBackQueue = false
  private var hasSpoken = false
  /// Made here (a new chat) rather than opened from the Mac's list.
  private let madeHere: Bool
  private var isWatching = false
  private var watchTask: Task<Void, Never>?
  private var reattachTask: Task<Void, any Error>?
  private var ownerHoldUntil = Date.distantPast
  private var preferredModel = ""
  private var preferredProvider = ""
  private var preferredEffort = ""
  /// Last time the gateway said anything about this chat's turn.
  @ObservationIgnored private var lastEventAt = Date()
  @ObservationIgnored private var livenessTask: Task<Void, Never>?
  /// The part of the stored history on screen, and where the next older page starts.
  @ObservationIgnored private var window = HistoryWindow.complete
  /// Bumped whenever `window` changes outside `loadOlder`, so a page read for an older window is dropped.
  @ObservationIgnored private var windowGeneration = 0
  /// Bumped when the held history is started over rather than extended (opening, a reattach whose
  /// newest page does not line up, a rewind): what is older than the window is not what it was.
  /// Find reads the rest of the chat again then.
  private(set) var historyEpoch = 0

  /// Rows read when a chat opens and on each look for news, and per older page while scrolling up.
  /// A long agentic turn runs to a hundred rows and more, most of them tool output.
  static let newestPageRows = 60
  static let olderPageRows = 100
  /// An idle chat whose newest turn is longer than this opens part way into that turn.
  static let openingRowCap = 400

  init(app: AppModel, profile: String, storedID: String, row: SessionSummary?, live: LiveSession?) {
    self.app = app
    self.profile = profile
    self.storedID = storedID
    queueState = app.queueState(profile: profile, storedID: storedID)
    section = row?.section ?? .chats
    prepared = live
    madeHere = live != nil && row == nil
    draft = app.preferences.draft(for: storedID)
    state.title = row?.title ?? ""
    state.info.model = row?.model ?? ""
    state.info.provider = row?.provider ?? ""
    state.info.cwd = row?.cwd ?? ""
    state.info.branch = row?.gitBranch ?? ""
    owner = app.owners[storedID]
    takeBack(app.takeLeftBehind(storedID: storedID))
  }

  #if DEBUG
  /// Offline UI-test data rendered by the real transcript, without attaching to a live chat.
  static func scrollPreview(app: AppModel, short: Bool) -> ChatModel {
    let chat = ChatModel(app: app, profile: "preview", storedID: "scroll-preview", row: nil, live: nil)
    chat.state.title = "Scroll preview"
    chat.isSlashPreview = ProcessInfo.processInfo.arguments.contains("--slash-preview")
    chat.isScrollPreview = true
    // Each launch starts with an empty composer: a draft a test left behind is not restored.
    chat.draft = ""
    // `--empty-chat`: a new chat with nothing sent yet (the particle field behind it).
    if ProcessInfo.processInfo.arguments.contains("--empty-chat") {
      chat.state.title = "New chat"
      chat.isLoading = false
      return chat
    }
    if !short {
      for turn in 1...8 {
        chat.state.items.append(.user("Earlier question \(turn)", timestamp: Double(turn)))
        let lines = (1...14).map { "Earlier reply \(turn), line \($0)." }.joined(separator: "\n\n")
        chat.state.items.append(TranscriptItem(kind: .assistant, text: lines))
      }
    }
    chat.state.items.append(.user("Inspect the latest change.", timestamp: 20))
    if ProcessInfo.processInfo.arguments.contains("--edited-files") {
      chat.state.items.append(contentsOf: editedFilesPreview())
      chat.state.items.append(TranscriptItem(kind: .assistant, text: "Updated the greeting in two places and wrote the notes."))
      chat.isLoading = false
      return chat
    }
    if ProcessInfo.processInfo.arguments.contains("--many-tools") {
      for index in 1...45 {
        chat.state.items.append(.tool(ToolCall(
          callID: "scroll-page-\(index)", name: "read_file", args: ["path": .string("file-\(index).swift")], isDone: true)))
      }
    } else {
      chat.state.items.append(.tool(ToolCall(callID: "scroll-preview-tool", name: "read_file", isDone: true)))
    }
    chat.state.items.append(TranscriptItem(kind: .assistant, text: "Latest reply. Everything is up to date."))
    // `--older-pages`: more of the chat waits on the "Mac" (canned rows), read as it is scrolled
    // up or searched (slowed by `TALARIA_UITEST_PAGE_DELAY`).
    if ProcessInfo.processInfo.arguments.contains("--older-pages") {
      chat.previewOlderRows = olderPagesPreview()
      chat.previewHeldRows = chat.state.items.count
      chat.previewFailuresLeft = ProcessInfo.processInfo.environment["TALARIA_UITEST_HISTORY_FAILS"].flatMap(Int.init) ?? 0
      let held: [JSONValue] = (0..<chat.previewHeldRows).map { ["id": .string("held-\($0)"), "role": "assistant"] }
      var window = HistoryWindow()
      _ = window.take(page: held, limit: held.count)
      chat.setWindow(window)
    }
    chat.isLoading = false
    return chat
  }

  /// `--older-pages`: forty older turns, each a question, a step and a long answer. Only two
  /// messages mention "zephyr" (one in Markdown, with an accent); a step's output does too, which
  /// Find leaves out.
  private static func olderPagesPreview() -> [JSONValue] {
    (1...40).flatMap { turn -> [JSONValue] in
      let id = Double(turn * 10)
      let question = turn == 35 ? "What changed in zephyr since then?" : "Older question \(turn)"
      var answer = (1...6).map { "Older answer \(turn), line \($0)." }.joined(separator: "\n\n")
      if turn == 3 { answer = "The **Zéphyr** build shipped on Tuesday.\n\n" + answer }
      return [
        ["id": .number(id), "role": "user", "content": .string(question), "timestamp": .number(Double(turn))],
        ["id": .number(id + 1), "role": "assistant", "content": "",
         "tool_calls": [["id": .string("older-\(turn)"), "function": ["name": "read_file", "arguments": "{}"]]]],
        ["id": .number(id + 2), "role": "tool", "tool_call_id": .string("older-\(turn)"),
         "content": "zephyr appears in this step's output"],
        ["id": .number(id + 3), "role": "assistant", "content": .string(answer), "timestamp": .number(Double(turn))],
      ]
    }
  }

  /// `--edited-files`: two edits to one file and a new file, each with an `inline_diff` in the
  /// shape Hermes sends (colored, under its "review diff" heading).
  private static func editedFilesPreview() -> [TranscriptItem] {
    func rendered(_ file: String, _ lines: [String]) -> String {
      let esc = "\u{1B}"
      let body = lines.map { line -> String in
        let code = line.hasPrefix("@@") ? "38;2;139;134;130"
          : line.hasPrefix("+") ? "38;2;255;255;255;48;2;19;87;20"
          : line.hasPrefix("-") ? "38;2;255;255;255;48;2;120;20;20" : "38;2;150;150;150"
        return "\(esc)[\(code)m\(line)\(esc)[0m"
      }
      return (["  ┊ review diff", "\(esc)[38;2;218;165;32ma/\(file) → b/\(file)\(esc)[0m"] + body).joined(separator: "\n")
    }
    func call(_ id: String, _ name: String, _ args: JSONValue, result: String, diff: String) -> TranscriptItem {
      var tool = ToolCall(callID: id, name: name, args: args, isDone: true)
      tool.result = result
      tool.inlineDiff = diff
      tool.duration = 0.2
      return .tool(tool, timestamp: 21)
    }
    let swift = "/Users/me/talaria/Sources/App/Greeting.swift"
    let notes = "/Users/me/talaria/docs/notes.md"
    let strings = "/Users/me/talaria/Sources/App/Strings.swift"
    return [
      call("edit-1", "patch", ["mode": "replace", "path": .string(swift)], result: #"{"success": true}"#,
        diff: rendered("Sources/App/Greeting.swift", [
          "@@ -1,6 +1,7 @@", " import Foundation", " ", "-func greet(_ name: String) -> String {",
          #"-  "Hello, \(name)""#, "+func greet(_ name: String, excited: Bool = false) -> String {",
          #"+  let mark = excited ? "!" : ".""#, #"+  return "Hello, \(name)\(mark)""#, " }",
        ])),
      call("edit-2", "patch", ["mode": "replace", "path": .string(swift)], result: #"{"success": true}"#,
        diff: rendered("Sources/App/Greeting.swift", [
          "@@ -12,3 +13,4 @@", " struct Banner {", "   let title: String", "+  let subtitle: String", " }",
        ])),
      call("write-1", "write_file", ["path": .string(notes)], result: #"{"bytes_written": 240, "resolved_path": "\#(notes)"}"#,
        diff: rendered("docs/notes.md", [
          "@@ -0,0 +1,4 @@", "+# Notes", "+",
          "+The Changes view wraps a long line like this one instead of scrolling sideways, so the whole edit stays"
            + " readable on a phone held upright, even when one sentence runs on for a long time without a break.",
          "+Greeting takes an excited flag now.",
        ])),
      // Longer than an edit message's preview, so it shows "Show all".
      call("write-2", "write_file", ["path": .string(strings)],
        result: #"{"bytes_written": 600, "resolved_path": "\#(strings)"}"#,
        diff: rendered("Sources/App/Strings.swift",
          ["@@ -0,0 +1,18 @@", "+enum Strings {"]
            + (1...16).map { "+  static let line\($0) = \"Line \($0)\"" } + ["+}"])),
    ]
  }

  /// Offline: plays running turns through the real event handling, so scroll tests can watch the
  /// transcript follow streamed text, tool steps, the working row and a queued message.
  func playPreviewTurns(count: Int, pace: Duration) async {
    func apply(_ type: String, _ payload: JSONValue = [:]) {
      _ = state.apply(event: type, payload: payload, now: now)
    }
    func words(_ text: String) async {
      for word in text.split(separator: " ", omittingEmptySubsequences: false) {
        apply("message.delta", ["text": .string(word + " ")])
        try? await Task.sleep(for: pace)
      }
    }
    let note = "I'll check how the transcript lays out the newest rows, then run the focused tests so the"
      + " follow behaviour is measured rather than guessed. This note wraps over several lines on a phone."
    let answer = (1...4).map { paragraph in
      "Paragraph \(paragraph) of the answer streams in word by word, growing the last row while the"
        + " transcript should keep its newest line in sight above the composer."
    }.joined(separator: "\n\n")
    for turn in 1...count {
      state.items.append(.user("Live question \(turn)", timestamp: now))
      scrollToEnd += 1
      state.beginTurn(now: now)
      try? await Task.sleep(for: pace * 8)
      await words(note)
      apply("message.interim", ["text": .string(note + " "), "already_streamed": .bool(true)])
      for step in 1...3 {
        apply("tool.start", [
          "tool_id": .string("live-\(turn)-\(step)"), "name": "terminal",
          "context": .string("xcrun devicectl device process launch --device 0000-\(step) com.example.app"),
        ])
        if turn == 1, step == 2 { queue.enqueue(text: "A follow-up written while the reply runs", attachments: [], now: now) }
        try? await Task.sleep(for: pace * 10)
        apply("tool.complete", ["tool_id": .string("live-\(turn)-\(step)"), "summary": "done", "duration_s": .number(0.4)])
        apply("reasoning.delta", ["text": .string("Checking step \(step)")])
        try? await Task.sleep(for: pace * 6)
      }
      await words(answer)
      apply("message.complete", ["text": .string(answer)])
      try? await Task.sleep(for: pace * 12)
    }
  }
  #endif

  private var client: HermesClient? { app?.client }

  /// A turn run elsewhere is laid out as live too: its work log counts tools so far, and its
  /// files wait for the answer.
  private func layOut() {
    rows = TranscriptLayout.rows(for: state.items, isStreaming: state.isStreaming || isRunningElsewhere, fileCache: &fileCache)
  }
  private var now: Double { Date().timeIntervalSince1970 }

  // MARK: Derived

  var isChannel: Bool { section.isChannel }
  /// Sending from here cannot reach this conversation itself; it starts a new version instead.
  var continuesAsNewVersion: Bool { owner != nil || isChannel }
  var title: String {
    let base = SessionSummary.baseTitle(state.title)
    return base.isEmpty ? "New chat" : base
  }
  /// The title as stored, empty when the chat has none yet.
  var savedTitle: String { SessionSummary.baseTitle(state.title) }
  /// A chat made here that nothing was sent in yet: the Mac has not stored it.
  var isUnsaved: Bool { madeHere && !hasSpoken }
  var isStreaming: Bool { state.isStreaming }
  var status: String { state.status }
  /// What the running turn is doing, in words for the transcript and the title bar.
  var activity: TurnActivity? {
    guard let activity = state.activity else {
      return isRunningElsewhere ? TurnActivity.inferred(from: state.items) : nil
    }
    if let liveID, app?.prompts.contains(where: { $0.sessionID == liveID }) == true { return .waiting }
    return activity
  }
  var turnStartedAt: Double? {
    state.turnStartedAt ?? (isRunningElsewhere ? TurnActivity.turnStart(in: state.items) : nil)
  }
  /// Every file the finished turns wrote, edited or delivered, once each, with every turn's diffs.
  var files: [FileReference] {
    TurnFiles.combined(rows.compactMap { row in
      if case .files(let turn) = row { return turn }
      return nil
    })
  }
  var info: SessionInfo { state.info }
  /// A reply is running or a message is on its way, so what is sent now waits in the queue.
  var isBusy: Bool { state.isStreaming || isSending }
  /// Sending now would queue the message rather than start a turn. `/btw` and `/bg` never queue,
  /// and neither does an edit.
  var sendQueues: Bool {
    isBusy && editing == nil && !continuesAsNewVersion && SlashInvocation(draft).flatMap(SideCommand.init) == nil
  }
  var canSend: Bool {
    guard !isReadOnly, !isBranching else { return false }
    // An edit sends its words alone; files picked before it wait for the next message.
    if editing != nil { return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // A photo still being shrunk has no bytes yet; it is ready in a moment.
    if attachments.contains(where: { $0.status == .preparing }) { return false }
    return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains { $0.isUsable }
  }
  var showsStop: Bool { state.isStreaming && !continuesAsNewVersion && !canSend }
  var isEmpty: Bool { rows.isEmpty && !isLoading }

  // MARK: Opening

  func open() async {
    guard !hasOpened else { return }
    hasOpened = true
    guard let client else { return }

    if let live = prepared {
      prepared = nil
      // A new chat, or a copy that brought its whole history along.
      adopt(live, history: .replace(TranscriptItem.items(fromHistory: live.messages), .complete))
      finishOpening()
      holdTakenBackQueueIfIdle()
      await cancelStoppedAdmissions()
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
      drainQueue()
      return
    }

    // Ask who has it open right before deciding how to open it.
    async let freshRow = try? client.session(storedID: storedID, profile: profile)
    let rosterProfiles = (app?.profileNames ?? []) + [profile]
    async let freshActive = try? client.activeSessions(profiles: rosterProfiles)
    if let owners = await app?.refreshOwners() { owner = owners[storedID] }
    let row = await freshRow
    // Our own backend running it is not "elsewhere": decide on a fresh live list, not the inbox's.
    if let active = await freshActive {
      app?.setLiveStatuses(active, profiles: rosterProfiles)
    } else {
      app?.invalidateLiveRoster(profiles: rosterProfiles)
    }
    if isClosed { return }
    // Only a fresh heartbeat absent from the gateway roster implies a separate process.
    // Creation provenance and an idle/starting status say nothing about ownership.
    if owner == nil, !isChannel, let other = elsewhereOwner(row: row) {
      owner = other
      isRunningElsewhere = true
    }
    if continuesAsNewVersion {
      await openWatching()
      return
    }
    // The session comes back without its transcript (a long chat's runs to megabytes); the newest
    // page of stored history is read alongside it, and older pages as the transcript scrolls up.
    let newest = Task { try await self.readNewest(client: client, toTurnStart: false) }
    do {
      try await client.rpc.waitUntilReady(timeout: 45)
      let live = try await client.resume(storedID: storedID, profile: profile, omitMessages: true)
      // Bind before receipt/history awaits. Events newer than this snapshot wait until its
      // transcript is adopted, rather than disappearing or being overwritten by that adoption.
      liveID = live.liveID
      app?.noteLive(live.liveID, storedID: storedID, profile: profile)
      await refreshQueuedReceipts(client: client, liveID: live.liveID)
      var history = try await newest.value
      if isClosed { return }
      if live.isRunning, history.window.hasOlder, !history.items.contains(where: { $0.kind == .user }) {
        // A running turn longer than an idle chat opens on: its start is needed to place it.
        history = try await readNewest(client: client, toTurnStart: true)
        if isClosed { return }
      }
      adopt(live, history: .replace(history.items, history.window))
      finishOpening()
      holdTakenBackQueueIfIdle()
      await recoverQueuedAdmissions()
      await cancelStoppedAdmissions()
      if let row = app?.row(storedID), row.unread { app?.setUnread(row, false) }
      if sendWhenReady {
        sendWhenReady = false
        await send()
      }
      drainQueue()
    } catch {
      if isClosed { return }
      loadError = error.localizedDescription
      if let history = try? await newest.value {
        state.items = history.items
        setWindow(history.window)
        isReadOnly = true
      }
      // Side answers are never in the Mac's history: they stay on a chat that only reads.
      restoreHeldSideItems(force: true)
      isLoading = false
    }
  }

  /// Stored history to put on screen with a live session.
  private enum History {
    /// Start the transcript over with these items.
    case replace([TranscriptItem], HistoryWindow)
    /// Fold the newest page into what is on screen; `items` and `window` are the page on its own,
    /// for when it does not line up.
    case newest(page: [JSONValue], items: [TranscriptItem], window: HistoryWindow)

    var items: [TranscriptItem] {
      switch self {
      case .replace(let items, _), .newest(_, let items, _): return items
      }
    }
  }

  private func adopt(_ live: LiveSession, history: History) {
    liveID = live.liveID
    subscriptionID = live.subscriptionID
    app?.noteLive(live.liveID, storedID: storedID, profile: profile)
    if let pending = live.pending { queueState.onMacList = pending }
    var next = state
    next.info.merge(live.info)
    if next.title.isEmpty { next.title = next.info.title }
    var fresh = history.items
    for rendered in queueState.renderedAdmissions {
      _ = claimQueuedUser(rendered.sent, in: fresh)
    }
    // The gateway does not say when a running turn started; for the timer, its message (stored when it
    // was sent) does.
    let turnStartedAt = live.turnStartedAt ?? (live.isRunning ? TurnActivity.turnStart(in: fresh) : nil)
    if let admissionID = live.inflight["admission_id"].string {
      startHandedOffPrompt(admissionID, in: &fresh)
    }
    settleHandedOffQueue(in: &fresh)
    switch history {
    case .replace(_, let newWindow):
      next.items = fresh
      next.applyInflight(live.inflight, turnStartedAt: live.turnStartedAt, now: now)
      setWindow(newWindow)
    case .newest(let page, _, let pageWindow):
      fold(newest: page, items: fresh, pageWindow: pageWindow, into: &next, inflight: live.inflight, turnStartedAt: live.turnStartedAt)
    }
    next.applyLiveStatus(isRunning: live.isRunning, startedAt: turnStartedAt, now: now)
    // Side answers are never in the Mac's history: put back the ones this app holds.
    next.restoreSideItems(app?.sideItems(profile: profile, storedID: storedID) ?? [])
    state = next
    lastEventAt = Date()
    for request in live.openRequests { app?.deliver(request) }
  }

  /// Puts the `/btw` and `/bg` notices and answers the app holds for this chat back on screen, or
  /// their newer copies in place of older ones: after its history is read afresh, and when one
  /// lands for it elsewhere. Opening does it itself when it adopts the history (`force` is for
  /// the opening paths that end without adopting).
  func restoreHeldSideItems(force: Bool = false) {
    guard !isClosed, force || !isLoading, let held = app?.sideItems(profile: profile, storedID: storedID), !held.isEmpty
    else { return }
    var next = state
    next.restoreSideItems(held)
    if next != state { state = next }
  }

  // MARK: Stored history, a page at a time

  /// The newest stored history: the newest page, read on back to where the newest turn starts
  /// (`toTurnStart`), else no further than `openingRowCap` rows. It starts where a turn starts
  /// when one was read, so no turn is shown in part.
  private func readNewest(client: HermesClient, toTurnStart: Bool) async throws -> (items: [TranscriptItem], window: HistoryWindow) {
    var window = HistoryWindow()
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: Self.newestPageRows, nextLimit: Self.olderPageRows, wholeTurns: true,
      fetch: { [storedID, profile] offset, limit in
        try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
      },
      until: { rows in
        TranscriptItem.items(fromStoredRows: rows).contains { $0.kind == .user } || (!toTurnStart && rows.count >= Self.openingRowCap)
      })
    return (TranscriptItem.items(fromStoredRows: rows), window)
  }

  /// The newest page alone, to fold into what is on screen: the raw page, its items, and a window
  /// of just that page for when it does not line up.
  private func readNewestPage(client: HermesClient) async throws -> History {
    var window = HistoryWindow()
    var newestPage: [JSONValue] = []
    let rows = try await HistoryWindow.readOlder(
      into: &window, firstLimit: Self.newestPageRows, nextLimit: Self.olderPageRows,
      fetch: { [storedID, profile] offset, limit in
        let page = try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
        if offset == 0 { newestPage = page }
        return page
      },
      until: { _ in true })
    return .newest(page: newestPage, items: TranscriptItem.items(fromStoredRows: rows), window: window)
  }

  /// Folds the newest page into `next`: on the end of what is held when it lines up, else in
  /// place of it (then older pages read again from there as the transcript scrolls up).
  private func fold(
    newest page: [JSONValue], items fresh: [TranscriptItem], pageWindow: HistoryWindow, into next: inout ChatState,
    inflight: JSONValue, turnStartedAt: Double?
  ) {
    let unnamed = window.reachedStart && !window.overlaps(newest: page) && window == HistoryWindow.complete
    if window.overlaps(newest: page) || unnamed,
      next.reconcileTail(fresh: fresh, inflight: inflight, turnStartedAt: turnStartedAt, now: now)
    {
      var updated = window
      if unnamed { updated.identify(newest: page) } else { updated.absorb(newest: page) }
      setWindow(updated, extending: true)
    } else {
      next.replace(with: fresh, inflight: inflight, turnStartedAt: turnStartedAt, now: now)
      setWindow(pageWindow)
    }
  }

  /// `extending`: the same history with more of it held, at either end; else it starts over.
  private func setWindow(_ new: HistoryWindow, extending: Bool = false) {
    window = new
    windowGeneration += 1
    if !extending { historyEpoch += 1 }
    if hasOlder != new.hasOlder { hasOlder = new.hasOlder }
  }

  /// Reads the next older page and puts it above what is on screen. The transcript calls this as
  /// it is scrolled near the top, and passes `untilStill` so the page lands once the scrolling
  /// stops: moving the content back into place mid-fling would cut the fling short.
  /// Returns whether a page landed.
  @discardableResult
  func loadOlder(untilStill: () async -> Void = {}) async -> Bool {
    guard hasOlder, !isLoadingOlder, !isLoading, !isClosed, let fetch = olderPages() else { return false }
    isLoadingOlder = true
    defer { isLoadingOlder = false }
    let generation = windowGeneration
    var older = window
    do {
      let rows = try await HistoryWindow.readOlder(
        into: &older, firstLimit: Self.olderPageRows, nextLimit: Self.olderPageRows, wholeTurns: true,
        fetch: fetch, until: { $0.contains(where: HistoryWindow.startsTurn) })
      await untilStill()
      // Whoever asked has moved on (Find closed or searching something else), or the transcript
      // was replaced meanwhile and this page belongs to the old one: it does not land.
      guard !Task.isCancelled, generation == windowGeneration, !isClosed else { return false }
      setWindow(older, extending: true)
      let items = TranscriptItem.items(fromStoredRows: rows)
      guard !items.isEmpty else { return true }
      var next = state
      next.items.insert(contentsOf: items, at: 0)
      state = next
      return true
    } catch {
      // A read given up on is not a failure to tell anyone about.
      if !isClosed, !Task.isCancelled, !(error is CancellationError) {
        app?.show("Could not load earlier messages: \(error.localizedDescription)", kind: .failure)
      }
      return false
    }
  }

  /// Reads older stored rows, `limit` at `offset` (`order=latest`), oldest first.
  private func olderPages() -> ((_ offset: Int, _ limit: Int) async throws -> [JSONValue])? {
    #if DEBUG
      // UI tests stand in for a slow connection: `TALARIA_UITEST_PAGE_DELAY=<seconds>`.
      let delay = ProcessInfo.processInfo.environment["TALARIA_UITEST_PAGE_DELAY"].flatMap(Double.init)
      if let stored = previewOlderRows {
        // `--older-pages`: older pages come from canned rows held before what is on screen.
        let held = previewHeldRows
        return { [weak self] offset, limit in
          if let delay { try await Task.sleep(for: .seconds(delay)) }
          if let self, self.previewFailuresLeft > 0 {
            self.previewFailuresLeft -= 1
            throw URLError(.notConnectedToInternet)
          }
          let end = max(0, stored.count - (offset - held))
          return Array(stored[max(0, end - limit)..<end])
        }
      }
    #endif
    guard let client else { return nil }
    return { [storedID, profile] offset, limit in
      #if DEBUG
        if let delay { try await Task.sleep(for: .seconds(delay)) }
      #endif
      return try await client.historyPage(storedID: storedID, profile: profile, offset: offset, limit: limit)
    }
  }

  // MARK: Find in chat

  /// Every stored row older than what is held, laid out as the transcript lays it out, for Find
  /// to search. What is on screen, and where the next older page starts, stay as they are.
  /// Throws `CancellationError` when the held history was started over while it read
  /// (`historyEpoch`): those rows were older than a window that is gone.
  func readOlderForFind() async throws -> (rows: [TranscriptRow], reachedStart: Bool) {
    guard hasOlder, let fetch = olderPages() else { return ([], true) }
    let epoch = historyEpoch
    var rest = window
    let rows = try await HistoryWindow.readOlder(
      into: &rest, firstLimit: Self.olderPageRows, nextLimit: Self.olderPageRows, fetch: fetch, until: { _ in false })
    guard epoch == historyEpoch, !Task.isCancelled else { throw CancellationError() }
    return (TranscriptLayout.rows(for: TranscriptItem.items(fromStoredRows: rows), isStreaming: false), rest.reachedStart)
  }

  /// Loads older pages, one at a time as scrolling up would, until `found` holds. False when the
  /// start was reached first, a page could not be read, or the caller was cancelled (then nothing
  /// more lands).
  func loadOlder(until found: () -> Bool, untilStill: () async -> Void) async -> Bool {
    while !found() {
      // A page the transcript asked for lands first.
      while isLoadingOlder, !isClosed, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
      guard !Task.isCancelled else { return false }
      if found() { return true }
      guard hasOlder, !isClosed, await loadOlder(untilStill: untilStill) else { return false }
    }
    return true
  }

  // MARK: Chats this app cannot drive right now

  private func openWatching() async {
    isWatching = true
    do {
      try await refreshWatched(first: true)
    } catch {
      loadError = error.localizedDescription
    }
    if isClosed { return }
    isLoading = false
    startWatching()
  }

  private func refreshWatched(first: Bool = false) async throws {
    guard let client else { return }
    if first || state.items.isEmpty {
      let history = try await readNewest(client: client, toTurnStart: isRunningElsewhere)
      if isClosed { return }
      state.items = history.items
      setWindow(history.window)
      restoreHeldSideItems(force: true)
      return
    }
    // Only the newest page: polling a long chat must not read all of it every few seconds.
    guard case .newest(let page, let fresh, let pageWindow) = try await readNewestPage(client: client), !isClosed else { return }
    var next = state
    fold(newest: page, items: fresh, pageWindow: pageWindow, into: &next, inflight: nil, turnStartedAt: nil)
    // A page that does not line up replaces the transcript, side answers held here included.
    next.restoreSideItems(app?.sideItems(profile: profile, storedID: storedID) ?? [])
    if next != state { state = next }
  }

  private func startWatching() {
    watchTask?.cancel()
    watchTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.isClosed else { return }
        try? await Task.sleep(for: .seconds(self.owner != nil ? 3.5 : 8))
        if Task.isCancelled || self.isClosed { return }
        if self.isBranching { continue }
        await self.app?.refreshLiveRoster()
        let owners = await self.app?.refreshOwners() ?? [:]
        var current = owners[self.storedID]
        if current == nil, !self.isChannel {
          if let row = try? await self.client?.session(storedID: self.storedID, profile: self.profile) {
            current = self.elsewhereOwner(row: row)
            self.isRunningElsewhere = current != nil
          } else if self.isRunningElsewhere {
            current = self.owner
          }
        } else {
          self.isRunningElsewhere = false
        }
        if Task.isCancelled || self.isClosed { return }
        if self.owner != nil, current == nil, !self.isChannel, Date() > self.ownerHoldUntil {
          await self.goLive()
          return
        }
        if current != nil || self.isChannel { self.owner = current }
        try? await self.refreshWatched()
      }
    }
  }

  /// A stand-in owner for a turn another Hermes process is running here, or nil.
  private func elsewhereOwner(row: SessionSummary?) -> ChatOwner? {
    guard let app, app.isRunningElsewhere(storedID, row: row) else { return nil }
    return ChatOwner(sessionID: storedID, surface: (row ?? app.row(storedID))?.createdSource ?? "")
  }

  /// The other process let go: drop any stale copy our backend still holds, then resume for real.
  private func goLive() async {
    watchTask = nil
    owner = nil
    isRunningElsewhere = false
    isWatching = false
    isReadOnly = false
    await dropLive()
    do {
      try await reattach()
    } catch {
      if !isClosed { app?.show("Could not reopen the chat: \(error.localizedDescription)", kind: .failure) }
    }
  }

  /// Forgets the attachment; the next send or reattach resumes the chat afresh.
  private func dropLive() async {
    liveID = nil
  }

  private func markOwned(by other: ChatOwner, holdSeconds: Double = 0) {
    guard !isClosed else { return }
    let wasOwned = owner != nil
    owner = other
    isWatching = true
    if holdSeconds > 0 { ownerHoldUntil = Date().addingTimeInterval(holdSeconds) }
    if !wasOwned { Task { await dropLive() } }
    var next = state
    next.isStreaming = false
    next.status = ""
    state = next
    startWatching()
  }

  /// Called when the app's owner map changes: the Mac may have just opened this chat.
  func ownersChanged() {
    guard !isClosed, !isLoading, !isWatching, !state.isStreaming, !isSending, let other = app?.owners[storedID] else { return }
    markOwned(by: other)
  }

  private func refused(message: String, text: String) async {
    let owners = await app?.refreshOwners() ?? [:]
    let surface = message.firstMatch(of: /(?i)opened by ([\w-]+)/).map { String($0.1) } ?? "desktop"
    markOwned(by: owners[storedID] ?? ChatOwner(sessionID: storedID, surface: surface), holdSeconds: 15)
    if !text.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
  }

  /// Copies the whole history into a conversation this app owns and moves the composer there.
  private func continueAsNewVersion(send: Bool) async {
    guard !isBranching, let client, let app else { return }
    isBranching = true
    defer { isBranching = false }
    do {
      try await client.rpc.waitUntilReady(timeout: 45)
      let row = app.row(storedID)
      let live = try await client.branch(
        storedID: storedID, profile: profile, cwd: state.info.cwd.isEmpty ? row?.cwd ?? "" : state.info.cwd,
        model: state.info.model.isEmpty ? row?.model ?? "" : state.info.model,
        provider: state.info.provider.isEmpty ? row?.provider ?? "" : state.info.provider)
      // The words moved to the new version: do not leave them behind in the original.
      let words = draft
      let picked = attachments
      draft = ""
      attachments = []
      let model = ChatModel(app: app, profile: profile, storedID: live.storedID, row: nil, live: live)
      model.state.title = state.title
      model.attachments = picked
      model.draft = words
      model.sendWhenReady = send && (!words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty)
      app.show(
        isChannel ? "Continuing as a Hermes chat. \(section.label) will not see it." : "Continuing here as a new version. The Mac keeps the original.",
        kind: .success, seconds: 4)
      app.replaceOpenChat(with: model)
      app.scheduleReload(after: 0.6)
    } catch {
      app.show("Could not continue here: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Staying attached

  func connectionReady() async {
    guard hasOpened, !isClosed, !isLoading, !isReadOnly, !isWatching else { return }
    try? await reattach()
    await recoverQueuedAdmissions()
    await cancelStoppedAdmissions()
    drainQueue()
  }

  func liveSessionReclaimed() async {
    liveID = nil
    guard !isClosed, !isLoading, !isReadOnly, !isWatching else { return }
    try? await reattach()
    await recoverQueuedAdmissions()
    await cancelStoppedAdmissions()
    drainQueue()
  }

  /// Re-binds this chat to a live backend session after a reconnect, a reclaim, or "session not found".
  private func reattach() async throws {
    if let running = reattachTask {
      try await running.value
      return
    }
    let task = Task { [weak self] in
      guard let self, let client = self.client else { return }
      // A never-spoken chat has no stored row. A plain resume of one that was reaped materializes
      // the row with the backend's process-wide model instead of the bot's, which that bot's provider
      // may reject. `lazy` re-attaches a live one and otherwise answers 4007; then mint a clean session.
      let spoken = self.state.items.contains { !$0.isPending && !$0.isLocal }
      var live: LiveSession
      do {
        live = try await client.resume(storedID: self.storedID, profile: self.profile, lazy: !spoken, omitMessages: true)
      } catch {
        let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
        if self.isClosed || wrapped.isConnectionLoss || spoken { throw error }
        let options = NewSessionOptions(
          model: self.preferredModel, provider: self.preferredProvider, reasoningEffort: self.preferredEffort)
        live = try await client.create(profile: self.profile, options: options)
        self.app?.preferences.noteStartedHere(live.storedID)
        let words = self.draft
        self.app?.preferences.setDraft("", for: self.storedID)
        self.storedID = live.storedID
        self.draft = words
      }
      if self.isClosed { return }
      await self.refreshQueuedReceipts(client: client, liveID: live.liveID)
      // A chat minted just now has no stored history yet; what was typed in it stays.
      let history = spoken
        ? try await self.readNewestPage(client: client) : History.newest(page: [], items: [], window: .complete)
      if self.isClosed { return }
      self.adopt(live, history: history)
    }
    reattachTask = task
    defer { reattachTask = nil }
    try await task.value
  }

  /// Waits for a usable connection and live session. Phones send right as they wake up.
  private func ensureLive() async throws {
    guard let client else { throw HermesError.notConnected }
    let isOpen = await client.rpc.isOpen
    if !isOpen {
      await client.rpc.kick()
      try await client.rpc.waitUntilReady(timeout: 45)
    }
    if let running = reattachTask { _ = try? await running.value }
    if liveID == nil { try await reattach() }
    if liveID == nil { throw HermesError.notConnected }
  }

  // MARK: Events

  private func finishOpening() {
    isReplayingOpeningEvents = true
    let buffered = openingEvents
    openingEvents = []
    for event in buffered { handle(event) }
    isReplayingOpeningEvents = false
    isLoading = false
  }

  func handle(_ event: GatewayEvent) {
    if isLoading, !isReplayingOpeningEvents {
      openingEvents.append(event)
      return
    }
    lastEventAt = Date()
    // The gateway lists the whole queue again whenever it changes.
    if event.type == "session.info", let pending = QueuedOnMac.list(event.payload["pending"]) {
      queueState.onMacList = pending
      reconcileSteered()
    }
    var next = state
    // Cancelling a waiting admission publishes message.complete, but does not finish the
    // unrelated execution currently streaming in this conversation.
    if event.type == "message.complete", event.payload["outcome"].string == "cancelled",
       event.payload["status"].string != "interrupted", let admissionID = event.admissionID {
      // A queued cancellation owns no execution. It can come from any viewer, even when
      // this phone never held its receipt. Executed interruptions carry status=interrupted.
      if let entry = queue.onMac.first(where: { queueState.receipts[$0.id]?["admission_id"].string == admissionID }),
         !queueState.takingBack.contains(entry.id) {
        queueState.receipts[entry.id] = ["admission_id": .string(admissionID), "status": "terminal", "outcome": "cancelled"]
        if queueState.cancellation == nil { settleHandedOffQueue(in: &next.items) }
      }
      state = next
      return
    }
    // A background wake or another client's turn is not necessarily our queued follow-up.
    if event.type == "message.start", let admissionID = event.admissionID {
      if !queueState.pendingAdmissions.isEmpty { queueState.startedAdmissions.insert(admissionID) }
      startHandedOffPrompt(admissionID, in: &next.items)
    }
    if event.type == "message.complete", let admissionID = event.admissionID,
       (["completed", "failed", "steered"].contains(event.payload["outcome"].stringValue) || event.payload["status"].string == "interrupted") {
      // A terminal event is also proof of execution when the matching start was missed.
      startHandedOffPrompt(admissionID, in: &next.items)
    }
    let effects = next.apply(event: event.type, payload: event.payload, now: now)
    state = next
    for effect in effects {
      switch effect {
      case .notice(let text): app?.show(text)
      case .failure(let text): app?.show(text, kind: .failure, seconds: 6)
      case .refused(let message, let text): Task { await refused(message: message, text: text) }
      case .sessionsChanged: app?.scheduleReload()
      case .requestCancelled(let id): app?.requestWithdrawn(id)
      case .turnFinished: UINotificationFeedbackGenerator().notificationOccurred(.success)
      case .sideAnswer(let item): app?.keepSideItem(item, profile: profile, storedID: storedID)
      }
    }
  }

  func rowChanged(_ row: SessionSummary) {
    // The stored title is the authority (a new version arrives untitled).
    if !row.title.isEmpty, row.title != state.title { state.title = row.title }
    // Another Hermes process started a turn here while this copy sat idle. Our own turns are
    // excluded: they stream events here, and the label is cleared within moments of the end.
    if !isClosed, !isLoading, !isWatching, !isChannel, !state.isStreaming, !isSending, !isBranching,
      Date().timeIntervalSince(lastEventAt) > 10, let other = elsewhereOwner(row: row)
    {
      isRunningElsewhere = true
      markOwned(by: other)
    }
  }

  // MARK: Staying truthful about a running turn

  /// While a turn runs, check now and then that it really is still running. A reply that
  /// finished while the socket was away never sends its end to us, and the screen would say
  /// "Working" forever.
  private func streamingChanged() {
    livenessTask?.cancel()
    livenessTask = nil
    guard state.isStreaming else {
      drainQueue()
      return
    }
    livenessTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self, !Task.isCancelled, !self.isClosed, self.state.isStreaming else { return }
        guard Date().timeIntervalSince(self.lastEventAt) > 20 else { continue }
        await self.confirmStillRunning()
      }
    }
  }

  private func confirmStillRunning() async {
    guard let client, let liveID, !isWatching else { return }
    guard let active = try? await client.activeSessions(profiles: [profile]) else { return }
    let entry = active.first { $0["id"].string == liveID }
    let status = entry?["status"].stringValue.lowercased() ?? ""
    if let entry, entry["status"].isNull || ["working", "waiting", "starting"].contains(status) { return }
    // Gone or idle: re-attach, which folds in the finished reply and takes `running` from the backend.
    lastEventAt = Date()
    try? await reattach()
  }

  // MARK: Questions

  func attach(clarify request: ServerRequest) {
    var next = state
    next.attach(clarify: request)
    state = next
    scrollToEnd += 1
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
  }

  /// `values[i]` holds the answers to question `i`, or `nil` to skip it.
  func answer(requestID: String, values: [[String]?]) {
    var next = state
    guard let outcome = next.answer(clarifyRequestID: requestID, values: values) else { return }
    state = next
    app?.clearWaiting(storedID: storedID)
    let profile = profile
    Task { await client?.answer(outcome.request, result: outcome.result, profile: profile) }
  }

  // MARK: Sending

  /// The composer's send. While a reply runs the message waits in the queue; otherwise it goes now.
  func send() async {
    guard !isReadOnly else { return }
    // An edit replaces the newest turn: never queued, and never run as a command.
    if editing != nil {
      await sendEdit()
      return
    }
    // `/retry` runs here, never queued or sent as words: while a reply runs it says to wait.
    if let command = SlashInvocation(draft), isRetry(command) {
      draft = ""
      await retry(command: command)
      return
    }
    if let command = SlashInvocation(draft), let side = SideCommand(command) {
      // Beside the reply: never queued behind it, sent into it, or stopping it. Picked files stay.
      draft = ""
      await startSide(side, for: command)
      return
    }
    if continuesAsNewVersion {
      // A command the phone leaves to the Mac is answered here, without making a new version.
      if let command = SlashInvocation(draft), command.name.isEmpty || SlashPolicy.isMacOnly(command.name) {
        draft = ""
        await startSlash(command, picked: [], origin: .composer).value
        return
      }
      if canSend, !isSending { await continueAsNewVersion(send: true) }
      return
    }
    guard canSend else { return }
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let picked = attachments.filter(\.isUsable)
    draft = ""
    attachments = []
    if isBusy {
      // A `/command` waits its turn like any message, and runs when it reaches the front.
      queue.enqueue(text: text, attachments: picked, now: now)
      return
    }
    await goOut(text: text, picked: picked, origin: .composer)
  }

  /// Where a message being delivered came from, which decides where it goes back if it fails.
  private enum Origin {
    case composer
    case queue(PromptQueue<ComposerAttachment>.Entry)
  }

  /// A `/command` runs as a command; anything else starts a turn with these words.
  private func goOut(text: String, picked: [ComposerAttachment], origin: Origin) async {
    if let command = SlashInvocation(text), isRetry(command) {
      // Nothing is sent with it: what was picked goes back to the composer.
      attachments = picked + attachments
      await retry(command: command)
    } else if let command = SlashInvocation(text) {
      await startSlash(command, picked: picked, origin: origin).value
    } else {
      await deliver(text: text, picked: picked, origin: origin)
    }
  }

  /// Starts a turn with this message: shows it as sending, uploads what was picked, submits.
  /// `display` is what the bubble shows when that differs from what is sent (a skill sends the
  /// expanded skill and shows the invocation that was typed); `typed` is what goes back to the
  /// composer if it fails. The Mac's copy is recognised by what was sent, whatever the bubble shows.
  /// True when the Mac took the turn.
  @discardableResult
  private func deliver(
    text: String, display: String? = nil, typed: String? = nil, picked: [ComposerAttachment], origin: Origin
  ) async -> Bool {
    let typed = typed ?? display ?? text
    #if DEBUG
    if isSlashPreview {
      var item = TranscriptItem.outgoing(text, shown: display, timestamp: now)
      item.isPending = false
      state.items.append(item)
      scrollToEnd += 1
      sendingHere = false
      return true
    }
    #endif
    guard let client else { return false }
    // A new turn settles any Try again whose answer was lost: it is never replayed after this.
    Self.retireRetry(rewindKey)
    var item = TranscriptItem.outgoing(text, shown: display, timestamp: now)
    item.attachments = picked.map { attachment in
      AttachmentChip(
        id: attachment.id, kind: attachment.kind == .image ? .image : .file, name: attachment.name,
        thumbnail: attachment.thumbnail?.jpegData(compressionQuality: 0.7))
    }
    let itemID = item.id
    state.items.append(item)
    scrollToEnd += 1
    sendingHere = true
    defer {
      sendingHere = false
      uploadStatus = ""
      drainQueue()
    }
    let fromQueue: Bool
    if case .queue = origin { fromQueue = true } else { fromQueue = false }

    do {
      var status = ""
      var attempt = 0
      while true {
        do {
          try await ensureLive()
          guard let liveID else { throw HermesError.notConnected }
          let staged = try await stage(picked, liveID: liveID, client: client)
          let full = ([text] + staged.references).filter { !$0.isEmpty }.joined(separator: "\n\n")
          // Kept apart from what the bubble shows, so the Mac's copy is recognised after a lost
          // acknowledgement (below) or a reload: a skill by the invocation the Mac's history reads
          // back, a composed message and its files as sent.
          update(itemID) { $0.submitted(full) }
          state.beginTurn(now: now)
          // A queued message must never cut into a reply the Mac is still wrapping up.
          status = try await client.submit(
            liveID: liveID, profile: profile, text: full, queued: fromQueue, images: staged.images)
          break
        } catch {
          let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
          guard attempt < 2, wrapped.isSessionGone || wrapped.isConnectionLoss else { throw error }
          attempt += 1
          if wrapped.isSessionGone { liveID = nil }
          try? await Task.sleep(for: .milliseconds(400))
          if wrapped.isConnectionLoss {
            // The ack may have been lost with the socket: if the turn already landed, do not send it twice.
            try? await ensureLive()
            if state.items.first(where: { $0.id == itemID })?.hasLanded == true {
              status = "recovered"
              break
            }
          }
        }
      }
      let sentAt = now
      update(itemID) {
        $0.isPending = false
        $0.timestamp = sentAt
      }
      hasSpoken = true
      if status == "queued", !fromQueue { app?.show("Queued. It goes out after the current reply.") }
      let shown = display ?? text
      if state.title.isEmpty { state.title = String((shown.isEmpty ? picked.first?.name ?? "" : shown).prefix(60)) }
      PushCenter.shared.noteSent(profile: profile, storedID: storedID, title: title)
      app?.recordSent(self)
      app?.scheduleReload(after: 2.5)
      return true
    } catch {
      state.isStreaming = false
      let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
      if isClosed {
        // Nobody sees this chat any more: it goes back where it came from, files and all, in the
        // copy of the chat that opens next.
        switch origin {
        case .composer: leaveBehind(words: typed, attachments: picked)
        case .queue(let entry): leaveBehind(queued: [entry], paused: true)
        }
        return false
      }
      if wrapped.isOwnedElsewhere {
        // Open on the Mac: nothing was sent. Keep the words and the attachments, and explain.
        state.items.removeAll { $0.id == itemID }
        attachments = picked + attachments
        await refused(message: wrapped.localizedDescription, text: typed)
        return false
      }
      update(itemID) {
        $0.isPending = false
        $0.isFailed = true
      }
      switch origin {
      case .composer:
        // What was typed goes back, never an expanded skill.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = typed }
        attachments = picked + attachments
        app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure, seconds: 6)
      case .queue(let entry):
        // Back at the front of the queue, held until sent by hand, so nothing is retried in a loop.
        queue.restore(entry)
        queue.pause()
        app?.show("Not sent: \(wrapped.localizedDescription). It is back in the queue.", kind: .failure, seconds: 6)
      }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(6))
        self?.state.items.removeAll { $0.id == itemID && $0.isFailed }
      }
      return false
    }
  }

  private func update(_ id: UUID, _ change: (inout TranscriptItem) -> Void) {
    guard let index = state.items.firstIndex(where: { $0.id == id }) else { return }
    var item = state.items[index]
    change(&item)
    state.items[index] = item
  }

  /// Uploads what was picked. Images are staged on the Mac and go with the turn; files come back as
  /// `@file:` references.
  private func stage(
    _ picked: [ComposerAttachment], liveID: String, client: HermesClient
  ) async throws -> (references: [String], images: [StagedImage]) {
    var references: [String] = []
    var images: [StagedImage] = []
    for (offset, attachment) in picked.enumerated() {
      guard let data = attachment.data else { continue }
      uploadStatus = picked.count > 1 ? "Uploading \(offset + 1) of \(picked.count)" : "Uploading \(attachment.name)"
      switch attachment.kind {
      case .image:
        images.append(try await client.attachImage(liveID: liveID, profile: profile, data: data, filename: attachment.name))
      case .file:
        references.append(try await client.attachFile(
          liveID: liveID, profile: profile, data: data, name: attachment.name, mimeType: attachment.mimeType))
      }
    }
    uploadStatus = ""
    return (references, images)
  }

  /// Stop the reply. Whatever is queued waits until sent by hand or resumed: stopping means stop.
  func stop() async {
    queueState.stoppedSteers.formUnion(queueState.steered.keys)
    queueState.cancelRequested.formUnion(queue.onMac.map(\.id))
    queueState.cancelRequested.formUnion(queueState.pendingAdmissions.keys)
    queue.pause()
    await cancelStoppedAdmissions()
    await interrupt()
  }

  private func interrupt() async {
    guard let client else { return }
    do {
      try await ensureLive()
      guard let liveID else { return }
      try await client.interrupt(liveID: liveID, profile: profile)
      state.status = "Stopping"
    } catch {
      app?.show(error.localizedDescription, kind: .failure)
    }
  }

  // MARK: Slash commands

  /// Starts a `/command`. Until it has run, or the turn it starts has been taken, it holds back
  /// the queue's hand-off to the Mac (`handOffQueue`), so nothing queued after it reaches the Mac
  /// first. It runs to the end even if the chat closes meanwhile.
  @discardableResult
  private func startSlash(_ command: SlashInvocation, picked: [ComposerAttachment], origin: Origin) -> Task<Void, Never> {
    let id = UUID()
    let task = Task {
      await self.runSlash(command, picked: picked, origin: origin)
      if self.slashRun?.id == id { self.slashRun = nil }
    }
    slashRun = (id, task)
    return task
  }

  /// Runs a `/command` the way the desktop app does (`SlashRunner`). A skill, or a message the
  /// command composed, starts a turn whose bubble shows what was typed; words to edit go back into
  /// the composer; anything else is a notice in the chat that only this phone shows. The command
  /// itself never goes to the model as words.
  private func runSlash(_ command: SlashInvocation, picked: [ComposerAttachment], origin: Origin) async {
    if let side = SideCommand(command) {
      // Queued before the phone ran these itself: it runs beside the chat, and the queue moves on.
      attachments = picked + attachments
      await startSide(side, for: command)
      drainQueue()
      return
    }
    sendingHere = true
    let result: SlashResult
    #if DEBUG
    if isSlashPreview {
      result = await SlashRunner.run(command, exec: Self.previewExec, dispatch: Self.previewDispatch)
    } else {
      result = await runOnMac(command)
    }
    #else
    result = await runOnMac(command)
    #endif
    if case .submit(let message, let display) = result.outcome {
      if !isClosed, let notice = result.notice { addNotice(notice, for: command) }
      // Sent even if the chat closed meanwhile, as a message sent just before leaving is.
      // `deliver` drains the queue when it is done.
      await deliver(text: message, display: display, typed: command.typed, picked: picked, origin: origin)
      return
    }
    sendingHere = false
    if isClosed {
      // Nobody sees this chat any more, so an answer has nowhere to show. What was not sent goes
      // to the copy of the chat that opens next: words to edit to its composer with the files
      // picked; a command that failed back where it came from (its queue entry, held, keeps its
      // place ahead of what was queued after it).
      switch (result.outcome, origin) {
      case (.failure, .queue(let entry)):
        leaveBehind(queued: [entry], paused: true)
      case (.prefill(let words), _):
        leaveBehind(words: words, attachments: picked)
      case (.failure, .composer):
        leaveBehind(words: command.typed, attachments: picked)
      case (.submit, _), (.output, _), (.macOnly, _):
        leaveBehind(attachments: picked)
      }
      return
    }
    if let notice = result.notice { addNotice(notice, for: command) }
    switch result.outcome {
    case .submit:
      return
    case .prefill(let words):
      keepAsDraft(words)
      // `/undo` took turns off the Mac's copy: show the chat as it is now.
      if !command.name.isEmpty, liveID != nil { try? await reattach() }
    case .output(let text):
      addNotice(text, for: command)
    case .macOnly:
      addNotice("Run /\(command.name) on the Mac for now.", for: command)
    case .failure(let text):
      addNotice(text, for: command)
    }
    // Nothing was sent: what was picked goes back to the composer.
    attachments = picked + attachments
    drainQueue()
  }

  /// Puts `words` in the composer ahead of whatever is there.
  private func keepAsDraft(_ words: String) {
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = [words, current].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// This chat has closed: what it had not sent goes to the copy of it that opens next (or is
  /// open already). This copy keeps the files too, as an open chat would.
  private func leaveBehind(
    words: String = "", attachments picked: [ComposerAttachment] = [],
    queued: [PromptQueue<ComposerAttachment>.Entry] = [], paused: Bool = false
  ) {
    attachments = picked + attachments
    // The queue is the conversation's (`ChatQueueState`), shared with the copy that opens next:
    // queued messages go straight back into it.
    if !queued.isEmpty {
      queue.takeBack(queued, paused: paused)
      leaveQueueBehind()
    }
    let left = LeftBehind(words: words, attachments: picked)
    guard !left.words.isEmpty || !left.attachments.isEmpty else { return }
    app?.leaveBehind(left, storedID: storedID)
  }

  /// Takes back what a closed copy of this chat had not sent: words ahead of the draft, files in
  /// the composer, queued messages in their place in the queue. Queued messages wait for a running
  /// reply; with none running they are held until sent by hand.
  func takeBack(_ left: LeftBehind) {
    if !left.words.isEmpty {
      // While a message is being edited, the words wait with the draft set aside for it.
      if editing != nil { setAside(left.words) } else { keepAsDraft(left.words) }
    }
    if !left.attachments.isEmpty { attachments = left.attachments + attachments }
    // Saved queued words only stand in for a queue the app lost when it restarted; the live
    // shared queue is the original, with its files.
    guard !left.queue.isEmpty, !queue.isShowing else { return }
    queue.takeBack(left.queue.entries, paused: left.queue.isPaused)
    if !hasOpened || isLoading {
      holdsTakenBackQueue = true
    } else if !isBusy {
      queue.pause()
    }
  }

  private func holdTakenBackQueueIfIdle() {
    guard holdsTakenBackQueue || queueState.leftWaiting else { return }
    holdsTakenBackQueue = false
    queueState.leftWaiting = false
    if !isBusy { queue.pause() }
  }

  private func runOnMac(_ command: SlashInvocation) async -> SlashResult {
    if SlashPolicy.isMacOnly(command.name) || command.name.isEmpty {
      // Answered without asking the Mac.
      return await SlashRunner.run(command, exec: { _ in .null }, dispatch: { _, _ in .null })
    }
    do {
      try await ensureLive()
    } catch {
      return SlashResult(.failure("Could not reach the Mac: \(error.localizedDescription)"))
    }
    let profile = profile
    return await SlashRunner.run(
      command,
      exec: { text in
        try await self.onLive { client, liveID in try await client.slashExec(liveID: liveID, profile: profile, command: text) }
      },
      dispatch: { name, arg in
        try await self.onLive { client, liveID in
          try await client.commandDispatch(liveID: liveID, profile: profile, name: name, arg: arg)
        }
      })
  }

  /// A call against this chat's live session, made once more after re-attaching when the gateway
  /// no longer knows this socket in it.
  private func onLive(_ call: @Sendable (HermesClient, String) async throws -> JSONValue) async throws -> JSONValue {
    var retried = false
    while true {
      try await ensureLive()
      guard let client, let liveID else { throw HermesError.notConnected }
      do {
        return try await call(client, liveID)
      } catch let error as HermesError where error.isSessionGone && !retried {
        retried = true
        self.liveID = nil
      }
    }
  }

  /// A command's answer under it in the chat, shown only on this phone.
  private func addNotice(_ text: String, for command: SlashInvocation) {
    let header = command.name.isEmpty ? "/" : "/\(command.name)"
    state.items.append(.slashNotice(text, command: header, timestamp: now))
    scrollToEnd += 1
  }

  // MARK: Side questions and background tasks

  /// `/btw` and `/bg` run beside the chat (`prompt.btw`, `prompt.background`), never through
  /// `slash.exec`: the slash worker prints their answer after its capture window, so it would
  /// never arrive. A notice shows at once; the answer lands later on this chat's events as its own
  /// card (`ChatState.addSideAnswer`). Both are held by the app (`AppModel.keepSideItem`), so a
  /// chat left and opened again still shows them.
  private func startSide(_ side: SideCommand, for command: SlashInvocation) async {
    guard !side.text.isEmpty else {
      addNotice(side.usage, for: command)
      return
    }
    guard !continuesAsNewVersion else {
      addNotice("This chat runs somewhere else, so \(side.name) can't run beside it from here.", for: command)
      return
    }
    let notice = TranscriptItem.sideNotice(side, timestamp: now)
    state.items.append(notice)
    app?.keepSideItem(notice, profile: profile, storedID: storedID)
    scrollToEnd += 1
    let taskID: String
    do {
      #if DEBUG
      if isSlashPreview {
        taskID = previewSide(side)
      } else {
        taskID = try await startSideOnMac(side)
      }
      #else
      taskID = try await startSideOnMac(side)
      #endif
    } catch {
      state.items.removeAll { $0.id == notice.id }
      app?.dropSideItem(notice.id, profile: profile, storedID: storedID)
      addNotice("Could not start \(side.name): \(error.localizedDescription)", for: command)
      return
    }
    // The answer can land before the task id does: it then takes this notice's words too.
    var next = state
    next.items.noteSideStarted(noticeID: notice.id, taskID: taskID, prompt: side.text)
    if next != state { state = next }
    app?.sideStarted(noticeID: notice.id, taskID: taskID, prompt: side.text, profile: profile, storedID: storedID, by: self)
  }

  /// The task id the gateway gave it.
  private func startSideOnMac(_ side: SideCommand) async throws -> String {
    let profile = profile
    let answer = try await onLive { client, liveID in
      .string(try await client.startSide(side, liveID: liveID, profile: profile))
    }
    return answer.stringValue
  }

  /// The composer's text changed: show, narrow or hide the `/` menu.
  private func slashDraftChanged() {
    // An edit sends words, so no `/` menu opens over it.
    let query = editing == nil ? SlashMenu.query(in: draft) : nil
    guard query != slashQuery else { return }
    slashQuery = query
    slashTask?.cancel()
    slashTask = nil
    guard let query, !isReadOnly, !isClosed else {
      if !slashItems.isEmpty { slashItems = [] }
      return
    }
    let key = query.lowercased()
    if let cached = slashCache[key] {
      slashItems = cached
      return
    }
    // What is on screen stays while the narrower list loads, so the menu does not flicker.
    slashTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, !Task.isCancelled else { return }
      guard let items = await self.completions(for: query), !Task.isCancelled, self.slashQuery == query else { return }
      self.slashCache[key] = items
      self.slashItems = items
    }
  }

  /// The menu's rows for `query`, or nil when the Mac could not say.
  private func completions(for query: String) async -> [SlashCompletion]? {
    #if DEBUG
    if isSlashPreview { return Self.previewCompletions(query) }
    #endif
    guard let client else { return nil }
    // A chat attached here names its session (project skills follow its folder); a new chat that
    // nothing was sent in yet, or one sending would continue elsewhere, names its bot.
    let session = isUnsaved || continuesAsNewVersion ? nil : liveID
    return try? await client.completeSlash(text: query, liveID: session, profile: profile)
  }

  /// Tapping a row: the `/token` becomes the name and a space; the keyboard stays up.
  func pickSlash(_ item: SlashCompletion) {
    UISelectionFeedbackGenerator().selectionChanged()
    draft = SlashMenu.picking(item)
  }

  #if DEBUG
  /// What the Mac would offer and answer, for the offline preview (`--slash-preview`).
  nonisolated private static let previewMenu: JSONValue = [
    "replace_from": 1,
    "items": [
      ["text": "work", "display": "/work", "meta": "⚡ Pick up a task, do it and hand it off", "kind": "skill"],
      ["text": "workdash", "display": "/workdash", "meta": "⚡ Open the work dashboard for a task", "kind": "skill"],
      ["text": "app-gardener", "display": "/app-gardener", "meta": "⚡ Grow the apps from approved ideas", "kind": "skill"],
      ["text": "review", "display": "/review", "meta": "⚡ Review a pull request", "kind": "skill"],
      ["text": "usage", "display": "/usage", "meta": "Show token usage and cost for this session", "kind": "command"],
      ["text": "goal", "display": "/goal", "meta": "Set a standing goal for this chat", "kind": "command"],
      ["text": "btw", "display": "/btw", "meta": "Ask a quick side question without interrupting", "kind": "command"],
      ["text": "background", "display": "/background", "meta": "Run a task in the background", "kind": "command"],
      ["text": "personality", "display": "/personality", "meta": "Set a personality overlay", "kind": "command"],
      ["text": "skin", "display": "/skin", "meta": "Switch the desktop theme", "kind": "command"],
    ],
  ]
  nonisolated private static let previewSkills: Set<String> = ["work", "workdash", "app-gardener", "review"]

  private static func previewCompletions(_ query: String) -> [SlashCompletion] {
    let word = query.dropFirst().lowercased()
    return SlashCompletion.items(from: previewMenu).filter { word.isEmpty || $0.name.dropFirst().lowercased().contains(word) }
  }

  nonisolated private static let previewExec: SlashRunner.Exec = { command in
    let name = command.split(separator: " ").first.map { $0.lowercased() } ?? ""
    if previewSkills.contains(name) {
      throw HermesError.rpc(code: 4018, message: "skill command: use command.dispatch for /\(name)", reason: nil)
    }
    if name == "usage" {
      return ["output": "Session usage\n  Input     12,480 tokens\n  Output     3,215 tokens\n  Cache hit  78%\n  Cost       $0.42"]
    }
    throw HermesError.rpc(code: 5030, message: "unknown command: /\(name)", reason: nil)
  }

  nonisolated private static let previewDispatch: SlashRunner.Dispatch = { name, arg in
    guard previewSkills.contains(name) else {
      throw HermesError.rpc(code: 4018, message: "not a quick/plugin/bundle/skill command: \(name)", reason: nil)
    }
    let invocation = arg.isEmpty ? "/\(name)" : "/\(name) \(arg)"
    let body = "[IMPORTANT: The user has invoked the \"\(name)\" skill, indicating they want you to follow its instructions."
      + " The full skill content is loaded below.]\n\n# \(name)\n\nThe whole skill, for the model."
    return ["type": "skill", "name": .string(name), "message": .string(body), "display": .string(invocation)]
  }

  /// A side question or task in the preview: its answer lands after a moment through the real
  /// event handling, delivered twice the way a reconnect can, and shows once. A task starting
  /// with "fail" fails.
  private func previewSide(_ side: SideCommand) -> String {
    let taskID = "\(side.kind == .btw ? "btw" : "bg")_\(UUID().uuidString.prefix(6).lowercased())"
    let failed = side.text.lowercased().hasPrefix("fail")
    let text = failed
      ? "error: The model provider refused the request (rate limited)."
      : side.kind == .btw
        ? "You were editing **Greeting.swift**:\n\n- added the `excited` flag\n- left `Strings.swift` alone"
        : "Done. Tidied **3 notes** and pushed them."
    var payload: [String: JSONValue] = ["task_id": .string(taskID), "text": .string(text)]
    if side.kind == .btw { payload["question"] = .string(side.text) }
    let event = GatewayEvent(
      type: side.kind == .btw ? "btw.complete" : "background.complete", sessionID: "", payload: .object(payload))
    let delay = Double(ProcessInfo.processInfo.environment["TALARIA_SIDE_PREVIEW_DELAY"] ?? "") ?? 1.5
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      self?.handle(event)
      self?.handle(event)
    }
    return taskID
  }
  #endif

  // MARK: Try again and Edit

  /// Try agains (and edits) whose rewind went out and whose resend nobody has claimed yet, by
  /// conversation (`profile/storedID`), shared by every copy of the chat: the answer may be lost,
  /// or still on its way to a copy that was left. The next Try again or edit sends that exact
  /// request first, as the desktop app does (`replay_only`): the Mac answers it with the receipt it
  /// already wrote, so a turn is never taken back twice, and the copy that gets a receipt first
  /// does the one resend.
  private static var retryOperations: [String: RetryOperation] = [:]
  private var rewindKey: String { "\(profile)/\(storedID)" }

  /// Ends the Try again waiting on this conversation (only `operation`, when given): nothing acts
  /// on it again, wherever its answer lands.
  private static func retireRetry(_ key: String, _ operation: RetryOperation? = nil) {
    guard let waiting = retryOperations[key], operation == nil || waiting === operation else { return }
    waiting.retire()
    retryOperations[key] = nil
  }

  /// Takes the one resend of `operation` for the caller; false when another copy of the chat
  /// took it first, or it was retired (another message went out meanwhile).
  private static func claimRetry(_ key: String, _ operation: RetryOperation) -> Bool {
    guard operation.claim() else { return false }
    if retryOperations[key] === operation { retryOperations[key] = nil }
    return true
  }

  /// Try again is offered here now: an idle chat this phone drives.
  var canRetry: Bool {
    !isBusy && !isReadOnly && !continuesAsNewVersion && !isLoading && !isRunningElsewhere && !isBranching
  }

  /// The messages the transcript offers Try again on: the newest from the person and the reply
  /// under it, while the chat is idle.
  var retryOffers: Set<UUID> {
    canRetry ? RetryTurn.offeredItems(in: state.items) : []
  }

  /// The message the transcript offers Edit on: the newest from the person, when Try again is
  /// offered and its words can be edited (no pictures, files or skill).
  var editOffers: Set<UUID> {
    canRetry ? EditTurn.offeredItems(in: state.items) : []
  }

  static let retryBusy = "Hermes is still replying. Wait for it to finish or stop it, then try again."
  static let retryNothing = "Nothing to try again yet."
  static let retryUnsupported = "That message has pictures or attachments, so it can't be sent again as it was."
  static let retryUnavailable = "Try again isn't available in this chat."
  static let retryChanged = "The chat changed on the Mac meanwhile. Try again."
  static let editBusy = "The chat started a reply on the Mac meanwhile. Your edit is still here: send it once the reply ends."
  static let editChanged = "The chat changed on the Mac meanwhile, so your message wasn't replaced. Your edit is in the composer."
  static let editUnavailable = "Edit isn't available in this chat."
  static let editCommand = "An edit sends words, not a / command. Cancel the edit to run a command."

  /// A message being edited in the composer: which one (the item on screen, and its stored row
  /// once known), and the draft that was in the composer, which comes back afterwards.
  struct Editing: Equatable {
    let itemID: UUID
    var rowID: Int?
    var stash: String
  }

  /// What goes out once the newest turn is taken back.
  @MainActor private enum Resend {
    /// Try again: the words the Mac took back.
    case same
    /// Edit: the person's new words, in place of the message being edited (`editing`).
    case edited(String)

    var edit: String? {
      if case .edited(let words) = self { return words }
      return nil
    }
    var busy: String { edit == nil ? ChatModel.retryBusy : ChatModel.editBusy }
    var unavailable: String { edit == nil ? ChatModel.retryUnavailable : ChatModel.editUnavailable }
    var changed: String { edit == nil ? ChatModel.retryChanged : ChatModel.editChanged }
    var failed: String { edit == nil ? "Couldn't try again" : "Couldn't send your edit" }
  }

  /// Try again on the newest turn (`/retry`, or the transcript's menu): that message and
  /// everything after it come off the Mac's copy, then the same words go out as a new turn.
  /// `command` is the typed `/retry`, under which notices show; from the menu they are toasts.
  func retry(command: SlashInvocation? = nil) async {
    await takeBackNewestTurn(.same, command: command)
  }

  /// Edit on the newest message: its words go into the composer under an "Editing your message"
  /// bar, and what was being written there is set aside until the edit goes out or is cancelled.
  func beginEdit(_ item: TranscriptItem) {
    guard editOffers.contains(item.id), let words = EditTurn.words(of: item) else { return }
    let stash = editing?.stash ?? draft
    // Set first: while editing, the draft kept for this chat is the one set aside.
    editing = Editing(itemID: item.id, rowID: item.rowID, stash: stash)
    draft = words
    focusComposer += 1
  }

  /// Cancel on the editing bar: the edited words go, and the draft set aside comes back.
  func cancelEdit() {
    guard let editing, !sendingHere else { return }
    self.editing = nil
    draft = editing.stash
  }

  /// The composer's send while editing: the edit replaces the newest turn, now or not at all.
  private func sendEdit() async {
    let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard editing != nil, !words.isEmpty, !sendingHere else { return }
    guard SlashInvocation(words) == nil else {
      app?.show(Self.editCommand)
      return
    }
    await takeBackNewestTurn(.edited(words))
  }

  /// The edit cannot replace the message any more (the chat moved on, or the turn was already
  /// taken back): the bar goes, and the composer on screen keeps the edited words, with the draft
  /// that was set aside after them. A copy of the chat that was left hands them to the chat's
  /// draft (`recoverEditedWords`).
  private func keepEditedWords(_ words: String) {
    if !isClosed, let editing {
      self.editing = nil
      let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      draft = EditTurn.keeping(edited: current.isEmpty ? words : draft, stash: editing.stash)
    } else {
      recoverEditedWords(words)
    }
  }

  /// Edited words that did not go out, put ahead of the chat's draft so neither is lost: in this
  /// composer while it is on screen, otherwise as words a closed chat had not sent
  /// (`leaveBehind`), which the copy on screen takes now and the next copy to open takes from the
  /// saved draft. Words already in the composer are not added again.
  private func recoverEditedWords(_ words: String) {
    let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    if isClosed {
      leaveBehind(words: words)
    } else if editing != nil {
      if !draft.contains(words) { setAside(words) }
    } else if !draft.contains(words) {
      keepAsDraft(words)
    }
  }

  /// The edit's words leave the composer: the bar goes and the draft set aside comes back. The
  /// composer takes no typing while the edit is on its way (`isSendingEdit`), but if its words
  /// changed after Send anyway (dictation that was still landing), what it holds now is not what
  /// went out, so it stays ahead of that draft. Returns whether it did.
  @discardableResult
  private func finishEditing(sent words: String) -> Bool {
    guard let editing else { return false }
    self.editing = nil
    let now = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let changed = !now.isEmpty && now != words.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = changed ? EditTurn.keeping(edited: now, stash: editing.stash) : editing.stash
    return changed
  }

  /// Puts `words` ahead of the draft set aside for an edit, not into the words being edited.
  private func setAside(_ words: String) {
    guard var editing, !editing.stash.contains(words) else { return }
    let stash = editing.stash.trimmingCharacters(in: .whitespacesAndNewlines)
    editing.stash = [words, stash].filter { !$0.isEmpty }.joined(separator: "\n\n")
    self.editing = editing
    app?.preferences.setDraft(editing.stash, for: storedID)
  }

  /// Takes the newest turn off the Mac's copy, then sends `resend`'s words as a new turn: Try
  /// again's same words, or an edit's new ones. Never rewinds from a stale view: when the Mac's
  /// newest message is not the stored row on screen (for an edit, the message being edited), or
  /// the chat moves on before the rewind lands or before the words go out, nothing more is taken
  /// back or sent and the chat reloads. An edit that does not go keeps its words in the composer,
  /// or in the chat's draft once its copy of the chat was left.
  private func takeBackNewestTurn(_ resend: Resend, command: SlashInvocation? = nil) async {
    func say(_ text: String, failure: Bool = false) {
      if let command {
        addNotice(text, for: command)
      } else {
        app?.show(text, kind: failure ? .failure : .info)
      }
    }
    let edit = resend.edit
    // This copy's edit was handed back to the composer already.
    var keptEdit = false
    // An edit's words this run sends once it claims a rewind (its own, or another copy's replayed
    // here), which it must not lose if they cannot go out.
    var claimedEdit: String?
    /// The edits this run cannot send stay where the person finds them, once each: this copy's in
    /// its composer (the bar goes), a claimed one ahead of the chat's draft, on screen or saved.
    func keepEdits() {
      if let edit, !keptEdit {
        keptEdit = true
        keepEditedWords(edit)
      }
      if let claimed = claimedEdit {
        claimedEdit = nil
        if claimed != edit { recoverEditedWords(claimed) }
      }
    }
    /// The chat is not as this view showed it: show the Mac's copy (on the copy on screen once
    /// the turn was taken back), then say so.
    func movedOn(onScreen: Bool = false) async {
      await (onScreen ? (visibleCopy ?? self) : self).reloadAfterRewind()
      let changed = edit != nil || claimedEdit != nil ? Self.editChanged : resend.changed
      keepEdits()
      say(changed, failure: true)
    }
    guard !isReadOnly, !continuesAsNewVersion else { return say(resend.unavailable) }
    // A toast, not a card: a card added now would land in the middle of the running reply. An
    // edit stays in the composer, to be sent once the reply ends; it never waits in the queue.
    guard !isBusy, !isRunningElsewhere else {
      app?.show(resend.busy)
      return
    }
    #if DEBUG
    if isScrollPreview { return await previewTakeBack(resend) }
    #endif
    guard let client else { return say(HermesError.notConnected.localizedDescription, failure: true) }
    sendingHere = true
    // Set once this rewind holds the one resend, until its words have gone out.
    var ownsResend = false
    defer {
      sendingHere = false
      if ownsResend { queueState.isResending = false }
      // What was sent meanwhile waited behind the resend; it goes now, from the copy on screen.
      (visibleCopy ?? self).drainQueue()
    }
    let key = rewindKey
    do {
      try await ensureLive()
      guard liveID != nil else { throw HermesError.notConnected }
      var taken: (operation: RetryOperation, receipt: RewindReceipt)?
      // A rewind still waiting on its answer goes first (the answer was lost, or is still on its
      // way to a copy of this chat that was left): the same request again, which the Mac answers
      // with the receipt it already wrote if it landed. Its edit, if it was one, goes with it.
      if let waiting = Self.retryOperations[key] {
        do {
          let replayed = try await rewindAgain(waiting.request, client: client)
          if replayed.didRewind {
            taken = (waiting, replayed)
          } else {
            Self.retireRetry(key, waiting)
          }
        } catch where Self.macAnswered(error) {
          // The Mac answered: that request is settled either way, and nothing came off.
          Self.retireRetry(key, waiting)
        }
      }
      if taken == nil {
        // A replay may have attached again.
        guard let liveID else { throw HermesError.notConnected }
        let snapshot = try await client.rewindSnapshot(liveID: liveID, profile: profile)
        if !snapshot.subscriptionID.isEmpty { subscriptionID = snapshot.subscriptionID }
        switch RetryTurn.pick(from: snapshot.rows) {
        case .nothing:
          // An edit's message is on screen, so a Mac with nothing to go back to has moved on.
          if edit != nil { return await movedOn() }
          return say(Self.retryNothing)
        case .unsupported:
          // The message being edited has no pictures, so the Mac's newest is another one.
          if edit != nil { return await movedOn() }
          return say(Self.retryUnsupported)
        case .target(let rowID, _):
          guard try await showsMacTurn(rowID, client: client), isEditTarget(rowID, resend) else {
            // The notice goes after the reload, which shows the Mac's copy in place of this one.
            return await movedOn()
          }
          // Known now, so an answer that is lost can be matched to this edit when it is replayed.
          if edit != nil { editing?.rowID = rowID }
          let operation = RetryOperation(request: RewindRequest(targetRowID: rowID, fences: snapshot.fences), edit: edit)
          Self.retireRetry(key)
          Self.retryOperations[key] = operation
          do {
            taken = (operation, try await client.rewind(operation.request, liveID: liveID, profile: profile))
          } catch where Self.macAnswered(error) {
            Self.retireRetry(key, operation)
            throw error
          }
        }
      }
      guard let taken else { return say(Self.retryNothing) }
      let operation = taken.operation
      // One resend per rewind: a copy of this chat that got the receipt first has sent it.
      guard Self.claimRetry(key, operation) else {
        if let edit {
          // Unless that copy is sending this very edit (the rewind carries its words), it did
          // not replace the message with these words.
          guard operation.isClaimed, operation.edit == edit else { return await movedOn() }
          if !isClosed { finishEditing(sent: edit) }
        }
        if !isClosed { await reloadAfterRewind() }
        return
      }
      // This copy sends the rewind's words now, so it keeps them if they cannot go.
      claimedEdit = operation.edit
      let receipt = taken.receipt
      guard receipt.didRewind else {
        if edit != nil || claimedEdit != nil { return await movedOn() }
        return say(Self.retryNothing)
      }
      // An edit is never changed back to the words the Mac took back, whoever claims its rewind;
      // an edit of the message taken back sends its words; any other edit stays in the composer.
      let plan = EditTurn.resend(
        claimed: operation.edit, retryText: receipt.retryText, caller: edit,
        callerEditsTarget: EditTurn.matches(receipt, rowID: editing?.rowID))
      claimedEdit = plan.isEdit ? plan.words : nil
      // From here until the words have gone out, every copy of this chat is busy: what is sent
      // meanwhile waits behind them, and no other Try again starts.
      ownsResend = true
      queueState.isResending = true
      if let kept = plan.kept {
        keptEdit = true
        keepEditedWords(kept)
        say(Self.editChanged, failure: true)
      }
      guard let text = plan.words, !text.isEmpty else {
        // Rows came off but there are no words to send: show the chat as it is now.
        await reloadAfterRewind()
        say(Self.retryNothing)
        return
      }
      // Shown on the copy of the chat on screen (this one, or the one opened after leaving it).
      let shown = visibleCopy ?? self
      shown.state.items = RetryTurn.cut(shown.state.items, rowID: receipt.targetID)
      await shown.reloadAfterRewind()
      // The receipt can be old (replayed after a lost answer, or late), and another device can
      // add a turn while the chat reloads: the words go out only onto the copy the rewind left,
      // so the Mac's newest row is read after the reload, right before they are sent.
      let newest: Int?
      do {
        newest = try await client.newestRowID(storedID: storedID, profile: profile)
      } catch {
        // Taken back, but the Mac's copy cannot be read now: the words wait in the composer.
        keepEdits()
        if !plan.isEdit {
          let composer = visibleCopy ?? self
          if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { composer.draft = text }
        }
        throw error
      }
      guard receipt.isCurrent(newestRowID: newest) else { return await movedOn(onScreen: true) }
      if plan.isEdit, text == edit, !isClosed, editing != nil {
        // The bar goes and the draft set aside comes back as the edited words leave the composer.
        let keptChanged = finishEditing(sent: text)
        let sent = await deliver(text: text, picked: [], origin: .composer)
        if !sent, !isClosed, !keptChanged {
          // Not sent: the edited words come back to the composer, the draft after them.
          draft = EditTurn.keeping(edited: text, stash: draft)
        }
        return
      }
      // Through the normal send path, from the copy on screen: if they do not go, they land in
      // its composer (an edit's ahead of what is there), or in the chat's draft once it is left.
      let composer = visibleCopy ?? self
      let sent = await composer.deliver(
        text: text, display: plan.isEdit ? nil : RetryTurn.display(for: text), picked: [], origin: .composer)
      if !sent, plan.isEdit, !composer.isClosed { composer.recoverEditedWords(text) }
    } catch {
      let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
      if wrapped.isStaleFence || Self.lostTarget(wrapped) {
        await movedOn()
      } else {
        // Nobody sees this copy's editing bar any more: its words wait in the chat's draft.
        if isClosed { keepEdits() }
        if case .rpc(_, _, "session_busy") = wrapped {
          say(resend.busy)
        } else {
          say("\(resend.failed): \(wrapped.localizedDescription)", failure: true)
        }
      }
    }
  }

  /// For an edit, whether the Mac's newest message (`rowID`) is the message being edited: the
  /// same item on screen, and the same stored row it was when Edit was picked, if that was known.
  private func isEditTarget(_ rowID: Int, _ resend: Resend) -> Bool {
    guard resend.edit != nil else { return true }
    guard let editing, editing.rowID == nil || editing.rowID == rowID else { return false }
    return EditTurn.isTarget(state.items, itemID: editing.itemID, rowID: rowID)
  }

  /// The Mac answered the rewind with a refusal, so nothing came off. Anything else (a dropped
  /// socket, a timeout) leaves its outcome unknown, and the request is kept for an exact retry.
  private static func macAnswered(_ error: any Error) -> Bool {
    if case .rpc = error as? HermesError { return true }
    return false
  }

  /// The Mac refused the rewind because the message it named is gone (taken back elsewhere).
  private static func lostTarget(_ error: HermesError) -> Bool {
    guard case .rpc(_, let message, let reason) = error, reason == "invalid_params" else { return false }
    return message.contains("no longer in session history")
  }

  /// Sends a rewind that went out before again, exactly as it was (same request id and fences).
  private func rewindAgain(_ request: RewindRequest, client: HermesClient) async throws -> RewindReceipt {
    guard let liveID else { throw HermesError.notConnected }
    do {
      return try await client.rewind(request, liveID: liveID, profile: profile)
    } catch let error as HermesError where error.isSessionGone {
      // This socket is new since (a reconnect): attach again, then send the same request.
      self.liveID = nil
      try await ensureLive()
      guard let again = self.liveID else { throw HermesError.notConnected }
      return try await client.rewind(request, liveID: again, profile: profile)
    }
  }

  /// Whether the newest message from the person on screen is the Mac's stored row `rowID`: the
  /// same turn, not just the same words. A message sent from here this visit has no row yet, so
  /// the newest stored page is folded in first to name it; if that page holds a newer turn than
  /// the screen did, the screen was behind.
  private func showsMacTurn(_ rowID: Int, client: HermesClient) async throws -> Bool {
    guard let shown = RetryTurn.shownTurn(state.items) else { return false }
    if shown.rowID == nil {
      guard case .newest(let page, let fresh, let pageWindow) = try await readNewestPage(client: client), !isClosed else {
        return false
      }
      var next = state
      fold(newest: page, items: fresh, pageWindow: pageWindow, into: &next, inflight: nil, turnStartedAt: nil)
      state = next
      // Lined up with what was on screen, the message keeps its place and learns its row.
      guard RetryTurn.shownTurn(state.items)?.id == shown.id else { return false }
    }
    return RetryTurn.showsTurn(state.items, rowID: rowID)
  }

  /// The copy of this chat on screen when this one was left: a Try again whose answer came back
  /// after leaving sends its words from there, so the new turn shows where the person is.
  private var visibleCopy: ChatModel? {
    guard isClosed, let open = app?.openChat, open !== self, open.storedID == storedID, !open.isClosed else { return nil }
    return open
  }

  /// Shows the Mac's copy after a rewind (or a refused one): the newest page, read afresh. The held
  /// window named rows that are gone, so it starts over rather than being extended.
  private func reloadAfterRewind() async {
    setWindow(HistoryWindow())
    try? await reattach()
  }

  /// `/retry`, which the phone runs itself (`retry`), never as a slash command on the Mac.
  private func isRetry(_ command: SlashInvocation) -> Bool { command.name == "retry" }

  #if DEBUG
  /// Offline: Try again (or an edit) on the preview transcript takes its newest turn off, shows
  /// the words that go out instead, and plays a fresh reply through the real event handling.
  private func previewTakeBack(_ resend: Resend) async {
    guard let user = state.items.last(where: { $0.kind == .user && !$0.isLocal }) else {
      app?.show(Self.retryNothing)
      return
    }
    var text = user.sentText ?? user.text
    if let edit = resend.edit {
      // `TALARIA_PREVIEW_EDIT_DELAY` (seconds) holds the edit on its way, as a slow Mac would,
      // so a test can try the composer while it is locked.
      if let delay = ProcessInfo.processInfo.environment["TALARIA_PREVIEW_EDIT_DELAY"].flatMap(Double.init), delay > 0 {
        sendingHere = true
        try? await Task.sleep(for: .seconds(delay))
        sendingHere = false
      }
      guard let editing, editing.itemID == user.id else {
        keepEditedWords(edit)
        app?.show(Self.editChanged, kind: .failure)
        return
      }
      text = edit
      finishEditing(sent: edit)
    }
    if let index = state.items.lastIndex(where: { $0.id == user.id }) { state.items = Array(state.items[..<index]) }
    state.items.append(.user(text, timestamp: now))
    scrollToEnd += 1
    state.beginTurn(now: now)
    let answer = "A fresh answer to the same question, written again from the start, one word at a time,"
      + " so the reply runs for a few seconds."
    for word in answer.split(separator: " ") {
      try? await Task.sleep(for: .milliseconds(300))
      _ = state.apply(event: "message.delta", payload: ["text": .string(word + " ")], now: now)
    }
    _ = state.apply(event: "message.complete", payload: ["text": .string(answer)], now: now)
  }
  #endif

  // MARK: Queue

  private func cancelStoppedAdmissions() async {
    if let cancellation = queueState.cancellation {
      await cancellation.value
      return
    }
    guard let client, let liveID, !queueState.cancelRequested.isEmpty else { return }
    let cancellation = Task {
      var attempted: Set<UUID> = []
      // An in-flight submit can acknowledge while a previous cancellation is awaiting I/O.
      // Re-read shared membership each time instead of freezing the initial onMac snapshot.
      while let entry = queue.onMac.first(where: { queueState.cancelRequested.contains($0.id) && !attempted.contains($0.id) }) {
        attempted.insert(entry.id)
        guard let admissionID = queueState.receipts[entry.id]?["admission_id"].string else { continue }
        do {
          try await client.cancelAdmission(liveID: liveID, profile: profile, admissionID: admissionID)
          let receipt = try await client.receipt(liveID: liveID, profile: profile, admissionID: admissionID)
          if queue.onMac.contains(where: { $0.id == entry.id }) { queueState.receipts[entry.id] = receipt }
        } catch {
          // Keep the exact receipt and Stop intent for reconnect; never assume cancellation.
          app?.show("Could not confirm that the queued message stopped. It remains on your Mac.", kind: .failure)
        }
      }
      let current = app?.openChat.flatMap { $0.queueState === queueState ? $0 : nil } ?? self
      current.settleHandedOffQueue(in: &current.state.items)
    }
    queueState.cancellation = cancellation
    await cancellation.value
    queueState.cancellation = nil
  }

  private func refreshQueuedReceipts(client: HermesClient, liveID: String) async {
    for entry in queue.onMac {
      guard let admissionID = queueState.receipts[entry.id]?["admission_id"].string,
            let receipt = try? await client.receipt(liveID: liveID, profile: profile, admissionID: admissionID),
            queue.onMac.contains(where: { $0.id == entry.id }) else { continue }
      queueState.receipts[entry.id] = receipt
    }
  }

  /// Receipts, not matching words or an arbitrary next turn, decide which entries left the queue.
  private func settleHandedOffQueue(in items: inout [TranscriptItem]) {
    var cancelled: [PromptQueue<ComposerAttachment>.Entry] = []
    for entry in queue.onMac where !queueState.takingBack.contains(entry.id) {
      guard let receipt = queueState.receipts[entry.id], let admissionID = receipt["admission_id"].string else { continue }
      switch receipt["status"].stringValue {
      case "started":
        startHandedOffPrompt(admissionID, in: &items)
      case "terminal":
        if receipt["outcome"].string == "cancelled" {
          queue.removeOnMac(entry.id)
          cancelled.append(entry)
          queueState.receipts[entry.id] = nil
          queueState.sentItems[entry.id] = nil
          queueState.cancelRequested.remove(entry.id)
        } else if ["completed", "failed", "interrupted", "steered"].contains(receipt["outcome"].stringValue) {
          startHandedOffPrompt(admissionID, in: &items)
        }
      default:
        // Queued or uncertain: keep the visible receipt, never automatically resubmit it.
        break
      }
    }
    // Prepend once in the Mac's FIFO order, not one at a time (which reverses A, B, C).
    queue.returnFromMac(cancelled)
  }

  private func startHandedOffPrompt(_ admissionID: String, in items: inout [TranscriptItem]) {
    guard let entry = queue.onMac.first(where: { queueState.receipts[$0.id]?["admission_id"].string == admissionID }) else { return }
    let sent = queueState.sentItems[entry.id] ?? TranscriptItem.user(entry.text, timestamp: entry.queuedAt)
    if !claimQueuedUser(sent, in: items) {
      items.append(sent)
      claimedQueueUserIDs.insert(sent.id)
    }
    queueState.renderedAdmissions.append((admissionID, sent))
    queue.removeOnMac(entry.id)
    queueState.receipts[entry.id] = nil
    queueState.sentItems[entry.id] = nil
    queueState.cancelRequested.remove(entry.id)
  }

  /// Stored history has no admission identity. Match its rows one-to-one, never many-to-one;
  /// a locally rendered row or a prior admission's stored row cannot hide the next prompt.
  private func claimQueuedUser(_ sent: TranscriptItem, in items: [TranscriptItem]) -> Bool {
    guard let shown = items.first(where: {
      $0.kind == .user && !claimedQueueUserIDs.contains($0.id)
        && ($0.id == sent.id || ($0.signature == sent.signature && ($0.timestamp ?? 0) >= (sent.timestamp ?? 0) - 1))
    }) else { return false }
    claimedQueueUserIDs.insert(shown.id)
    return true
  }

  /// Sends the next queued message once nothing runs.
  private func drainQueue() {
    guard !isClosed, !isLoading, !isReadOnly, !continuesAsNewVersion, queueState.handoff == nil,
          queueState.pendingAdmissions.isEmpty, let entry = queue.next(isBusy: isBusy) else { return }
    queue.remove(entry.id)
    if let command = SlashInvocation(entry.text) {
      // Started right here, so the hand-off to the Mac already waits for it.
      startSlash(command, picked: entry.attachments, origin: .queue(entry))
    } else {
      Task { await deliver(text: entry.text, picked: entry.attachments, origin: .queue(entry)) }
    }
  }

  /// "Send now": the running reply takes this message in and answers it. Words go straight into
  /// the reply (`session.redirect`). Photos need a turn of their own, so the reply stops and this
  /// message goes first. With nothing running it is simply sent.
  func sendNow(_ id: UUID) async {
    guard let entry = queue.entries.first(where: { $0.id == id }), !entry.isDelivering else { return }
    if entry.isAwaitingReceipt {
      await recoverQueuedAdmissions()
      return
    }
    queue.resume()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if !isBusy {
      queue.remove(id)
      await goOut(text: entry.text, picked: entry.attachments, origin: .queue(entry))
      return
    }
    // A command cannot go into a running reply as words: it runs next, once the reply stops.
    guard entry.attachments.isEmpty, !entry.text.isEmpty, state.isStreaming, SlashInvocation(entry.text) == nil else {
      await goesNext(id)
      return
    }
    queue.setDelivering(id, true)
    do {
      try await ensureLive()
      guard let liveID, let client else { throw HermesError.notConnected }
      let status = try await client.redirect(liveID: liveID, profile: profile, text: entry.text)
      switch status {
      case "redirected":
        queue.remove(id)
        var next = state
        next.insertCorrection(entry.text, now: now)
        state = next
        hasSpoken = true
        scrollToEnd += 1
      case "queued":
        // The reply was still starting: the Mac runs this as the very next turn.
        queue.remove(id)
        state.items.append(TranscriptItem(kind: .user, text: entry.text, timestamp: now))
        hasSpoken = true
        scrollToEnd += 1
        app?.show("Your Mac takes it right after this reply.")
      default:
        queue.setDelivering(id, false)
        await goesNext(id)
      }
    } catch {
      queue.setDelivering(id, false)
      let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
      if wrapped.isConnectionLoss || wrapped == .notConnected {
        app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure)
      } else {
        // This reply cannot take messages in (an older agent): stop it and send this first.
        await goesNext(id)
      }
    }
  }

  /// Makes an entry the next to go and ends the reply, so it goes out as soon as the reply stops.
  private func goesNext(_ id: UUID) async {
    queue.promote(id)
    queue.resume()
    // A reply that already ended without telling us would never hand over to the queue. Finding
    // that out re-attaches, and the idle chat drains the queue on its own.
    await confirmStillRunning()
    guard queue.entries.contains(where: { $0.id == id }) else { return }
    if state.isStreaming { await interrupt() } else { drainQueue() }
  }

  /// Takes a queued message back into the composer to change it.
  func editQueued(_ id: UUID) {
    guard queue.entries.contains(where: { $0.id == id && !$0.isDelivering && !$0.isAwaitingReceipt }) else { return }
    guard let entry = queue.remove(id) else { return }
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = [entry.text, current].filter { !$0.isEmpty }.joined(separator: "\n\n")
    attachments = entry.attachments + attachments
  }

  func deleteQueued(_ id: UUID) {
    guard queue.entries.contains(where: { $0.id == id && !$0.isDelivering && !$0.isAwaitingReceipt }) else { return }
    queue.remove(id)
  }

  // MARK: Messages waiting on the Mac

  /// Edit on a message this app handed to the Mac: it leaves the Mac's queue and comes back into
  /// the composer.
  func editOnMac(_ id: UUID) async {
    if await takeBackFromMac(id) != nil { editQueued(id) }
  }

  func removeOnMac(_ id: UUID) async {
    if await takeBackFromMac(id) != nil { queue.remove(id) }
  }

  /// Send now on a message this app handed to the Mac. Words go into the running reply straight
  /// from the Mac's queue (`prompt.steer_queued`); a message with photos, or one the reply cannot
  /// take, comes back here and goes the way a local Send now does.
  func sendNowOnMac(_ id: UUID) async {
    guard let entry = queue.onMac.first(where: { $0.id == id }), !queueState.takingBack.contains(id) else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if isBusy, state.isStreaming, entry.attachments.isEmpty, !entry.text.isEmpty, macRow(for: entry)?.canSteer != false,
       let admissionID = queueState.receipts[id]?["admission_id"].string {
      queueState.takingBack.insert(id)
      do {
        try await ensureLive()
        guard let client, let liveID else { throw HermesError.notConnected }
        _ = try await client.steerQueued(liveID: liveID, profile: profile, admissionID: admissionID)
        queueState.takingBack.remove(id)
        queue.removeOnMac(id)
        queueState.receipts[id] = nil
        queueState.sentItems[id] = nil
        queueState.cancelRequested.remove(id)
        queueState.steered[admissionID] = (entry, showCorrection(entry.text))
        return
      } catch {
        queueState.takingBack.remove(id)
        let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
        if wrapped.isConnectionLoss || wrapped == .notConnected {
          app?.show("Not sent: \(wrapped.localizedDescription)", kind: .failure)
          return
        }
        // Refused (the reply cannot take messages in, or it just ended): send it another way.
      }
    }
    if await takeBackFromMac(id) != nil { await sendNow(id) }
  }

  /// Send now on another device's message in the Mac's queue: the running reply takes it in.
  func sendNowFromMac(_ row: QueuedOnMac) async {
    guard row.canSteer, isBusy, !queueState.actingOn.contains(row.admissionID) else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    queueState.actingOn.insert(row.admissionID)
    defer { queueState.actingOn.remove(row.admissionID) }
    do {
      try await ensureLive()
      guard let client, let liveID else { throw HermesError.notConnected }
      _ = try await client.steerQueued(liveID: liveID, profile: profile, admissionID: row.admissionID)
      showCorrection(row.text)
    } catch {
      app?.show("Your Mac could not hand it to the reply. It stays queued.", kind: .failure)
    }
  }

  /// Edit on another device's message: it leaves the Mac's queue and its words come into this
  /// composer, to go from here.
  func editFromMac(_ row: QueuedOnMac) async {
    guard row.canSteer, !queueState.actingOn.contains(row.admissionID) else { return }
    // The words come over first: if the Mac cancels it but the answer is lost, they are not.
    let before = draft
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = [row.text, current].filter { !$0.isEmpty }.joined(separator: "\n\n")
    if await withdraw(row) == .stillQueuedOrSent { draft = before }
  }

  func removeFromMac(_ row: QueuedOnMac) async {
    _ = await withdraw(row)
  }

  private enum Withdrawal { case cancelled, stillQueuedOrSent, unknown }

  @discardableResult
  private func showCorrection(_ text: String) -> UUID? {
    var next = state
    next.insertCorrection(text, now: now)
    let shown = next.items.last?.id
    state = next
    hasSpoken = true
    scrollToEnd += 1
    return shown
  }

  /// A message this app sent now from the Mac's queue goes back to waiting there when the reply
  /// never took it in. Track it again, and take back the bubble that said it was sent. After a
  /// Stop it must not run: cancel it, and it comes back here held.
  private func reconcileSteered() {
    for (admissionID, steered) in queueState.steered {
      let row = queueState.onMacList.first { $0.admissionID == admissionID }
      guard let row else {
        // Taken in, or settled: nothing more to follow.
        queueState.steered[admissionID] = nil
        queueState.stoppedSteers.remove(admissionID)
        continue
      }
      guard row.isWaiting else { continue }
      queueState.steered[admissionID] = nil
      if let shown = steered.shown { state.items.removeAll { $0.id == shown } }
      queue.restoreOnMac(steered.entry)
      queueState.receipts[steered.entry.id] = ["admission_id": .string(admissionID), "status": "queued"]
      if queueState.stoppedSteers.remove(admissionID) != nil {
        queueState.cancelRequested.insert(steered.entry.id)
        queue.pause()
        Task { await cancelStoppedAdmissions() }
      }
    }
  }

  /// Cancels one message still waiting in the Mac's queue. Checks first that it is still
  /// waiting: `prompt.cancel` on one that started would stop that reply.
  private func cancelWaiting(admissionID: String) async throws -> Bool {
    try await ensureLive()
    guard let client, let liveID else { throw HermesError.notConnected }
    let before = try await client.receipt(liveID: liveID, profile: profile, admissionID: admissionID)
    guard before["status"].string == "queued" else { return false }
    try await client.cancelAdmission(liveID: liveID, profile: profile, admissionID: admissionID)
    let after = try await client.receipt(liveID: liveID, profile: profile, admissionID: admissionID)
    return after["status"].string == "terminal" && after["outcome"].string == "cancelled"
  }

  private func withdraw(_ row: QueuedOnMac) async -> Withdrawal {
    guard !queueState.actingOn.contains(row.admissionID) else { return .stillQueuedOrSent }
    queueState.actingOn.insert(row.admissionID)
    defer { queueState.actingOn.remove(row.admissionID) }
    do {
      if try await cancelWaiting(admissionID: row.admissionID) {
        queueState.onMacList.removeAll { $0.admissionID == row.admissionID }
        return .cancelled
      }
      app?.show("It already went out.")
      return .stillQueuedOrSent
    } catch {
      app?.show("Could not confirm with your Mac. Check the queue before sending.", kind: .failure)
      return .unknown
    }
  }

  /// Takes one of this app's messages back out of the Mac's queue, keeping its photos and files.
  /// Nil when it already went out (then it shows in the conversation as usual).
  private func takeBackFromMac(_ id: UUID) async -> PromptQueue<ComposerAttachment>.Entry? {
    guard queue.onMac.contains(where: { $0.id == id }), !queueState.takingBack.contains(id),
          let admissionID = queueState.receipts[id]?["admission_id"].string else { return nil }
    queueState.takingBack.insert(id)
    defer { queueState.takingBack.remove(id) }
    do {
      if try await cancelWaiting(admissionID: admissionID) {
        queueState.receipts[id] = nil
        queueState.sentItems[id] = nil
        queueState.cancelRequested.remove(id)
        queueState.onMacList.removeAll { $0.admissionID == admissionID }
        return queue.takeBackFromMac(id)
      }
      if let client, let liveID,
         let receipt = try? await client.receipt(liveID: liveID, profile: profile, admissionID: admissionID) {
        queueState.receipts[id] = receipt
      }
      queueState.takingBack.remove(id)
      settleHandedOffQueue(in: &state.items)
      app?.show("It already went out.")
    } catch {
      app?.show("Could not reach your Mac. The message is still queued there.", kind: .failure)
    }
    return nil
  }

  func resumeQueue() {
    if queueState.pendingAdmissions.isEmpty {
      queue.resume()
      drainQueue()
      return
    }
    Task {
      await recoverQueuedAdmissions()
      guard queueState.pendingAdmissions.isEmpty else { return }
      queue.resume()
      drainQueue()
    }
  }

  /// The app is going to sleep, or this chat is closing, while messages wait for a reply that is
  /// still running. Hand them to the Mac, which runs them after the reply with this app suspended
  /// (`prompt.submit` with `queued`). A paused queue stays here: the person stopped the agent.
  func handOffQueue() async {
    if let handoff = queueState.handoff {
      await handoff.value
      return
    }
    let handoff = Task { await submitWaitingQueue() }
    queueState.handoff = handoff
    await handoff.value
    queueState.handoff = nil
    queueState.startedAdmissions = []
    if let current = app?.openChat, current.queueState === queueState { current.drainQueue() }
  }

  private func submitWaitingQueue() async {
    // A command that left the queue is still being worked out: what was queued after it waits
    // until its turn has been taken, or it would reach the Mac first.
    while let running = slashRun?.task { await running.value }
    await recoverQueuedAdmissions()
    guard queueState.pendingAdmissions.isEmpty else { return }
    // A Try again's words go out before anything queued after it: those wait here meanwhile.
    guard !queueState.isResending else { return }
    guard !queue.isEmpty, !queue.isPaused, isBusy, !continuesAsNewVersion, let client, let liveID else { return }
    for id in queue.entries.map(\.id) {
      guard !queue.isPaused else { return }
      guard let entry = queue.entries.first(where: { $0.id == id }), !entry.isDelivering else { continue }
      // The Mac's queue takes words only; a command and what follows it wait here for the phone.
      if SlashInvocation(entry.text) != nil { return }
      queue.setDelivering(entry.id, true)
      do {
        let staged = try await stage(entry.attachments, liveID: liveID, client: client)
        guard !queue.isPaused, queue.entries.contains(where: { $0.id == id && $0.isDelivering }) else {
          queue.setDelivering(id, false)
          return
        }
        let full = ([entry.text] + staged.references).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var sent = TranscriptItem.user(full, timestamp: now)
        sent.images = staged.images.map(\.path)
        let pending = ChatQueueState.PendingAdmission(liveID: liveID, submissionID: entry.submissionID, text: full, images: staged.images, sent: sent)
        queueState.pendingAdmissions[id] = pending
        let receipt = try await client.admit(
          liveID: liveID, profile: profile, text: full, queued: true, images: staged.images,
          submissionID: pending.submissionID)
        await acknowledgeHandoff(id, pending: pending, receipt: receipt)
      } catch {
        queue.setDelivering(entry.id, false)
        // Only an explicit precommit refusal makes the entry unsent. Internal errors, timeouts
        // and disconnects can all happen AFTER admission; do not guess that they mean "not sent".
        if case HermesError.rpc(_, _, let reason) = error, reason == "queue_full" {
          queueState.pendingAdmissions[id] = nil
        }
        if queueState.pendingAdmissions[id] != nil {
          queue.setAwaitingReceipt(id, true)
          queue.pause()
          app?.show("Delivery unconfirmed. Held until the original message can be checked on your Mac.", kind: .failure, seconds: 6)
        }
        return
      }
    }
  }

  /// Recovery only replays the original admission, never redirect/deliver or another upload.
  /// Shared across screen models just like handoff, so competing wake/reopen/Send now paths join it.
  private func recoverQueuedAdmissions() async {
    if let recovery = queueState.recovery {
      await recovery.value
      return
    }
    guard queue.entries.contains(where: \.isAwaitingReceipt) else { return }
    let recovery = Task {
      for id in queue.entries.filter(\.isAwaitingReceipt).map(\.id) {
        guard let pending = queueState.pendingAdmissions[id], let client else { continue }
        queue.setDelivering(id, true)
        defer { queue.setDelivering(id, false) }
        do {
          try await ensureLive()
          // The target is part of admission identity. Never replay into a replacement session.
          guard liveID == pending.liveID else { throw HermesError.notConnected }
          let receipt = try await client.admit(
            liveID: pending.liveID, profile: profile, text: pending.text, queued: true, images: pending.images,
            submissionID: pending.submissionID)
          await acknowledgeHandoff(id, pending: pending, receipt: receipt)
        } catch {
          if (error as? HermesError)?.isSessionGone == true { liveID = nil }
          queue.pause()
          return // Still unconfirmed: keep both the immutable payload and the hold.
        }
      }
    }
    queueState.recovery = recovery
    await recovery.value
    queueState.recovery = nil
  }

  private func acknowledgeHandoff(_ id: UUID, pending: ChatQueueState.PendingAdmission, receipt: JSONValue) async {
    queueState.receipts[id] = receipt
    queueState.sentItems[id] = pending.sent
    queueState.pendingAdmissions[id] = nil
    queue.setDelivering(id, false)
    queue.setAwaitingReceipt(id, false)
    queue.moveToMac(id)
    hasSpoken = true
    if queueState.cancelRequested.contains(id) { await cancelStoppedAdmissions() }
    if let current = app?.openChat, current.queueState === queueState {
      current.settleHandedOffQueue(in: &current.state.items)
      if let admissionID = receipt["admission_id"].string,
         queueState.startedAdmissions.remove(admissionID) != nil {
        current.startHandedOffPrompt(admissionID, in: &current.state.items)
      }
    }
  }

  // MARK: Attachments

  func addImage(data: Data, name: String) {
    var attachment = ComposerAttachment(kind: .image, name: name)
    let id = attachment.id
    attachment.mimeType = "image/jpeg"
    attachments.append(attachment)
    Task {
      let prepared = await ImagePreparation.prepare(data, name: name)
      guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
      if let prepared {
        attachments[index].data = prepared.data
        attachments[index].name = prepared.name
        attachments[index].thumbnail = prepared.thumbnail
        attachments[index].status = .ready
      } else {
        attachments[index].status = .failed("Could not read the image")
      }
    }
  }

  func addFile(data: Data, name: String, mimeType: String) {
    var attachment = ComposerAttachment(kind: .file, name: name)
    attachment.mimeType = mimeType
    if data.count > 200_000_000 {
      attachment.status = .failed("Larger than 200 MB")
    } else {
      attachment.data = data
      attachment.status = .ready
    }
    attachments.append(attachment)
  }

  func removeAttachment(_ id: UUID) {
    attachments.removeAll { $0.id == id }
  }

  // MARK: Model and effort

  /// Loads the providers and their models. What is on screen stays while a fresh copy loads, and
  /// a plan the backend had not checked yet is looked at again shortly.
  func loadCatalog() async {
    guard let client else { return }
    catalogError = nil
    for attempt in 0..<2 {
      do {
        try await ensureLive()
        guard let liveID else { return }
        let fresh = try await client.modelCatalog(liveID: liveID, profile: profile)
        if fresh != catalog { catalog = fresh }
        guard attempt == 0, fresh.contains(where: \.isCheckingPlan) else { return }
        try await Task.sleep(for: .seconds(4))
      } catch is CancellationError {
        return
      } catch {
        if catalog == nil { catalogError = error.localizedDescription }
        return
      }
    }
  }

  /// Switches this conversation's model. Returns a confirmation prompt when the backend wants one.
  func setModel(_ model: String, provider: String, confirmed: Bool = false) async -> String? {
    guard let client else { return nil }
    do {
      try await ensureLive()
      guard let liveID else { return nil }
      let result = try await client.setModel(liveID: liveID, profile: profile, model: model, provider: provider, confirmed: confirmed)
      if result.needsConfirmation {
        return result.confirmationMessage.isEmpty
          ? "\(ModelName(model).display) costs more than usual. Use it for this chat?" : result.confirmationMessage
      }
      state.info.model = result.model
      state.info.provider = provider
      preferredModel = result.model
      preferredProvider = provider
      catalog = nil
      let name = ModelName(result.model).display
      app?.show(result.isDeferred ? "\(name) takes over after this reply" : "This chat now uses \(name)", kind: .success)
      if !result.warning.isEmpty { app?.show(result.warning, seconds: 5) }
    } catch {
      app?.show("Could not switch model: \(error.localizedDescription)", kind: .failure)
    }
    return nil
  }

  func setEffort(_ effort: String) async {
    guard let client else { return }
    do {
      try await ensureLive()
      guard let liveID else { return }
      let settled = try await client.setReasoningEffort(liveID: liveID, profile: profile, effort: effort)
      state.info.reasoningEffort = settled
      preferredEffort = settled
    } catch {
      app?.show("Could not change effort: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Metadata

  func rename(to title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let client else { return }
    do {
      if let liveID, !continuesAsNewVersion {
        try await client.setTitle(liveID: liveID, profile: profile, title: trimmed)
      } else if let row = app?.row(storedID) {
        try await client.update(row, title: trimmed)
      }
      state.title = trimmed
      app?.scheduleReload(after: 0.4)
    } catch {
      app?.show("Could not rename: \(error.localizedDescription)", kind: .failure)
    }
  }

  // MARK: Leaving

  func leave() {
    isClosed = true
    watchTask?.cancel()
    watchTask = nil
    livenessTask?.cancel()
    livenessTask = nil
    slashTask?.cancel()
    slashTask = nil
    app?.preferences.setDraft(editing?.stash ?? draft, for: storedID)
    // Picked files wait for the next copy of the chat, as the words do.
    if !attachments.isEmpty { app?.leaveBehind(LeftBehind(attachments: attachments), storedID: storedID) }
    if !queue.isEmpty {
      Task {
        await handOffQueue()
        leaveQueueBehind()
      }
    }
    // Stop following the chat once nothing here waits on it. A running reply stays followed, so a
    // question it asks still reaches this app.
    if let liveID, let client, !state.isStreaming, !isSending, queue.isEmpty {
      let subscription = subscriptionID
      let profile = profile
      subscriptionID = ""
      Task { try? await client.detach(liveID: liveID, subscriptionID: subscription, profile: profile) }
    }
  }

  /// Queued messages that could not go to the Mac (the queue was paused, a command waits in it, or
  /// the handover failed) stay in the chat's shared queue, each its own entry with its files.
  /// Their words are also saved, so they come back (held, without files) after the app restarts.
  private func leaveQueueBehind() {
    app?.preferences.setQueued(queue.entries.map(\.text), for: storedID)
    if !queue.isEmpty { queueState.leftWaiting = true }
  }

  /// The phone is going to sleep. Messages waiting for the running reply go to the Mac now, or
  /// they would wait until the app is opened again.
  func wentToBackground() {
    guard !queue.isEmpty, !queue.isPaused, isBusy else { return }
    let task = BackgroundTask()
    task.id = UIApplication.shared.beginBackgroundTask(withName: "Hand queued messages to the Mac") { task.end() }
    Task {
      await handOffQueue()
      task.end()
    }
  }
}

/// One Try again or edit, from its rewind to its single resend, shared by every copy of the chat
/// (`ChatModel.retryOperations`). Whoever gets a receipt for it first claims the resend; once
/// claimed or retired it is never acted on again, wherever another answer to it lands. An edit's
/// new words travel with it, so whichever copy claims it sends the edit, never the old words.
@MainActor final class RetryOperation {
  let request: RewindRequest
  /// The edited words that go out in place of the turn this rewind takes back; nil for Try again.
  let edit: String?
  /// A copy of the chat took the resend (rather than it being retired unsent).
  private(set) var isClaimed = false
  private var isSettled = false

  init(request: RewindRequest, edit: String? = nil) {
    self.request = request
    self.edit = edit
  }

  /// Takes the operation for the caller; false when it was taken or retired already.
  func claim() -> Bool {
    guard !isSettled else { return false }
    isSettled = true
    isClaimed = true
    return true
  }

  /// Ends the operation with nobody sending it.
  func retire() {
    isSettled = true
  }
}

/// Extra time iOS grants an app that is going to the background, ended once the work is done.
@MainActor private final class BackgroundTask {
  var id = UIBackgroundTaskIdentifier.invalid

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}

/// Shrinks a picked photo to what a model can use (2048 px on the long side) and makes a thumbnail.
enum ImagePreparation {
  struct Prepared: Sendable {
    let data: Data
    let name: String
    let thumbnail: UIImage
  }

  nonisolated static func prepare(_ data: Data, name: String) async -> Prepared? {
    await Task.detached(priority: .userInitiated) {
      guard let image = UIImage(data: data) else { return nil }
      let full = resized(image, maxSide: 2048)
      guard let jpeg = full.jpegData(compressionQuality: 0.86) else { return nil }
      let base = (name as NSString).deletingPathExtension
      // The thumbnail is what the message shows until the Mac's copy loads, so it is screen sized.
      return Prepared(data: jpeg, name: (base.isEmpty ? "image" : base) + ".jpg", thumbnail: resized(image, maxSide: 720))
    }.value
  }

  nonisolated private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    let scale = min(1, maxSide / max(longest, 1))
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
