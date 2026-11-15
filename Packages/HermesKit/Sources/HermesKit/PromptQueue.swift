import Foundation

/// Messages written while a reply was running, waiting their turn on this device.
///
/// Sending while the agent works does not cut into its reply: the message waits here and goes
/// out as the next turn once the reply ends, one message per turn, oldest first. "Send now"
/// hands one to the running reply instead (the app does that through `session.redirect`).
///
/// Stop pauses the queue: stopping means the person wants the agent to stop, so nothing queued
/// starts on its own until they send one or resume.
///
/// Generic over what an entry carries besides its text, so the app can keep picked photos with
/// their message while this type stays free of UI and testable on macOS.
public struct PromptQueue<Attachment: Sendable>: Sendable {
  public struct Entry: Identifiable, Sendable {
    public let id: UUID
    /// Wire identity is stable through uncertain retries, but renewed after definite cancellation.
    public var submissionID: String
    public var text: String
    public var attachments: [Attachment]
    /// Seconds since 1970.
    public var queuedAt: Double
    /// A "Send now" for this entry is on its way to the Mac.
    public var isDelivering = false
    /// Submission may have committed, but its acknowledgement was lost. Recover its original
    /// identity before allowing an edit, removal or alternate delivery; this is not an active send.
    public var isAwaitingReceipt = false
    /// Preserve admission FIFO even when cancellations return in separate batches.
    fileprivate var handoffSequence: Int?

    public init(id: UUID = UUID(), text: String, attachments: [Attachment] = [], queuedAt: Double) {
      self.id = id
      submissionID = id.uuidString.lowercased()
      self.text = text
      self.attachments = attachments
      self.queuedAt = queuedAt
    }
  }

  public private(set) var entries: [Entry] = []
  /// Set by Stop. Entries wait until one is sent by hand or the queue is resumed.
  public private(set) var isPaused = false
  /// Entries given to the Mac's own queue because the phone was going to sleep. The Mac runs
  /// them after the reply; they show here until their turn starts.
  public private(set) var onMac: [Entry] = []
  private var nextHandoffSequence = 0

  public init() {}

  /// Nothing waits on this phone (entries on the Mac aside).
  public var isEmpty: Bool { entries.isEmpty }
  public var count: Int { entries.count }
  /// Something to show: waiting here or on the Mac.
  public var isShowing: Bool { !entries.isEmpty || !onMac.isEmpty }

  /// The Mac accepted this entry into its own queue.
  public mutating func moveToMac(_ id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    // Transfer is not consumption: Stop still holds even when the last local entry leaves.
    var entry = entries.remove(at: index)
    entry.handoffSequence = nextHandoffSequence
    nextHandoffSequence += 1
    onMac.append(entry)
  }

  /// One admission started or settled; other queued admissions still wait on the Mac.
  @discardableResult
  public mutating func removeOnMac(_ id: UUID) -> Entry? {
    guard let index = onMac.firstIndex(where: { $0.id == id }) else { return nil }
    return onMac.remove(at: index)
  }

  /// The Mac started the turn for what it was holding, or it no longer holds it.
  public mutating func takeOnMac() -> [Entry] {
    defer { onMac = [] }
    return onMac
  }

  /// Entries the Mac dropped (a stopped reply clears its queue) come back here, held.
  public mutating func returnFromMac(_ dropped: [Entry]) {
    guard !dropped.isEmpty else { return }
    for var entry in dropped {
      entry.isDelivering = false
      entry.isAwaitingReceipt = false
      entry.submissionID = UUID().uuidString.lowercased()
      let index = entries.firstIndex {
        guard let order = $0.handoffSequence else { return true }
        return order > (entry.handoffSequence ?? -1)
      } ?? entries.endIndex
      entries.insert(entry, at: index)
    }
    isPaused = true
  }

  @discardableResult
  public mutating func enqueue(text: String, attachments: [Attachment] = [], now: Double) -> Entry {
    let entry = Entry(text: text, attachments: attachments, queuedAt: now)
    entries.append(entry)
    return entry
  }

  @discardableResult
  public mutating func remove(_ id: UUID) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
    defer { if entries.isEmpty { isPaused = false } }
    return entries.remove(at: index)
  }

  /// Takes every entry out, oldest first.
  public mutating func removeAll() -> [Entry] {
    defer {
      entries = []
      isPaused = false
    }
    return entries
  }

  /// Puts an entry back at the front, where it was before a send that failed.
  public mutating func restore(_ entry: Entry) {
    var entry = entry
    entry.isDelivering = false
    entries.removeAll { $0.id == entry.id }
    entries.insert(entry, at: 0)
  }

  /// Moves an entry to the front so it is the next to go out.
  public mutating func promote(_ id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
    entries.insert(entries.remove(at: index), at: 0)
  }

  public mutating func setDelivering(_ id: UUID, _ value: Bool) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].isDelivering = value
  }

  public mutating func setAwaitingReceipt(_ id: UUID, _ value: Bool) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].isAwaitingReceipt = value
  }

  public mutating func pause() {
    if isShowing { isPaused = true }
  }

  public mutating func resume() {
    isPaused = false
  }

  /// The entry to send now that nothing runs, if the queue is flowing.
  public func next(isBusy: Bool) -> Entry? {
    guard !isBusy, !isPaused, !entries.contains(where: \.isAwaitingReceipt) else { return nil }
    return entries.first { !$0.isDelivering }
  }
}
