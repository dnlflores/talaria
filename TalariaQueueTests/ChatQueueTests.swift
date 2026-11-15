import HermesKit
import XCTest
@testable import Talaria

/// Exercise production navigation and handoff against a local-only gateway fixture.
@MainActor
final class ChatQueueTests: XCTestCase {
  private let base = "http://127.0.0.1:19129"
  private var app: AppModel!

  private func control(_ body: JSONValue) async throws {
    var request = URLRequest(url: URL(string: base + "/__control")!)
    request.httpMethod = "POST"
    request.httpBody = body.data()
    _ = try await URLSession.shared.data(for: request)
  }

  private func calls() async throws -> [JSONValue] {
    let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/__metrics")!)
    return try JSONValue.parse(data)["calls"].array ?? []
  }

  private func waitUntil(_ label: String, _ predicate: () async throws -> Bool) async throws {
    let start = ContinuousClock.now
    while try await !predicate(), start.duration(to: .now) < .seconds(5) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let satisfied = try await predicate()
    XCTAssertTrue(satisfied, label)
  }

  override func setUp() async throws {
    continueAfterFailure = true
    XCTAssertEqual(ProcessInfo.processInfo.environment["TALARIA_SERVER"], base)
    try await control([:])
    app = AppModel()
    app.preferences.setDraft("", for: "fixture")
    try await app.connect(to: base)
    let client = try XCTUnwrap(app.client)
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 5)
    await app.refreshProfilesNow()
    try await control(["gateway_running": true])
  }

  override func tearDown() async throws {
    app?.openChat?.leave()
    await app?.client?.rpc.stop()
    app?.preferences.setDraft("", for: "fixture")
    app = nil
  }

  private func openChat() async -> ChatModel {
    let chat = app.chat(profile: "selected", storedID: "fixture")
    app.chatAppeared(chat)
    await chat.open()
    return chat
  }

  private func configure(_ body: JSONValue) async throws {
    var request = URLRequest(url: URL(string: base + "/__configure")!)
    request.httpMethod = "POST"
    request.httpBody = body.data()
    _ = try await URLSession.shared.data(for: request)
  }

  private func emit(_ type: String, admissionID: String, payload: JSONValue = [:]) async throws {
    var request = URLRequest(url: URL(string: base + "/__emit")!)
    request.httpMethod = "POST"
    request.httpBody = JSONValue.object(["frames": .array([
      ["jsonrpc": "2.0", "method": "event", "params": ["type": .string(type), "session_id": "fixture",
        "admission_id": .string(admissionID), "payload": payload]],
    ])]).data()
    _ = try await URLSession.shared.data(for: request)
  }

  func testOtherViewerQueuedCancellationKeepsForegroundExecutionRunning() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "Local waits for the original"
    await chat.send()
    let localID = try XCTUnwrap(chat.queue.entries.first?.id)
    try await emit("message.start", admissionID: "original-turn")
    try await emit("message.delta", admissionID: "original-turn", payload: ["text": "Original still working"])
    try await waitUntil("foreground text arrived") { chat.state.items.contains { $0.text == "Original still working" && $0.isStreaming } }
    let client = try XCTUnwrap(app.client)
    let receipt = try await client.rpc.call("prompt.submit", ["session_id": "fixture", "profile": "selected",
      "submission_id": "desktop-follow-up", "text": "Desktop waiting admission", "queued": true])
    let admissionID = try XCTUnwrap(receipt["admission_id"].string)
    XCTAssertTrue(chat.queue.onMac.isEmpty, "the desktop admission is deliberately not locally tracked")
    _ = try await client.rpc.call("prompt.cancel", ["session_id": "fixture", "profile": "selected", "admission_id": .string(admissionID)])
    // A later delta is an event-pump barrier; it must extend the still-running original bubble.
    try await emit("message.delta", admissionID: "original-turn", payload: ["text": " after cancellation"])
    try await waitUntil("cancellation and subsequent delta processed") { chat.state.items.contains { $0.text.contains("after cancellation") } }
    XCTAssertTrue(chat.isStreaming, "F1: another viewer's queued cancellation must not finish the foreground turn")
    XCTAssertTrue(chat.state.items.contains { $0.text == "Original still working after cancellation" && $0.isStreaming })
    XCTAssertEqual(chat.queue.entries.map(\.id), [localID], "local work cannot drain until the original actually ends")
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 1)
    // Real active interruption is cancelled/status-interrupted, not a queued cancellation.
    await chat.stop()
    try await waitUntil("active interruption must still finish the foreground") { !chat.isStreaming }
    XCTAssertTrue(chat.queue.isPaused)
    app.chatDisappeared(chat)
  }

  func testIdenticalTextAdmissionsEachRenderTheirOwnUserBubble() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    for _ in 0..<2 {
      chat.draft = "continue"
      await chat.send()
    }
    await chat.handOffQueue()
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    let admissionIDs = submissions.map { "admitted-" + $0["params"]["submission_id"].stringValue }
    XCTAssertEqual(Set(admissionIDs).count, 2)
    try await emit("message.complete", admissionID: "original-turn", payload: ["text": "Original finished", "outcome": "completed", "status": "complete"])
    try await waitUntil("original ended") { !chat.isStreaming }
    for (index, admissionID) in admissionIDs.enumerated() {
      try await emit("message.start", admissionID: admissionID)
      try await emit("message.complete", admissionID: admissionID, payload: ["text": .string("Answer \(index)"), "outcome": "completed", "status": "complete"])
      try await waitUntil("matching answer rendered") { chat.state.items.contains { $0.kind == .assistant && $0.text == "Answer \(index)" } }
    }
    XCTAssertTrue(chat.queue.onMac.isEmpty)
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user && $0.text == "continue" }.count, 2, "F5: equal text does not make distinct admissions the same message")
    XCTAssertEqual(chat.state.items.filter { $0.kind == .assistant && $0.text.hasPrefix("Answer ") }.count, 2)
    app.chatDisappeared(chat)
  }

  func testIdenticalTextHistoryRowCannotBeReusedByTheNextAdmissionAfterNavigation() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    for _ in 0..<2 {
      chat.draft = "continue"
      await chat.send()
    }
    await chat.handOffQueue()
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    let admissionIDs = submissions.map { "admitted-" + $0["params"]["submission_id"].stringValue }
    app.chatDisappeared(chat)
    try await emit("message.start", admissionID: admissionIDs[0])
    try await emit("message.complete", admissionID: admissionIDs[0], payload: ["text": "First answer", "outcome": "completed", "status": "complete"])
    var request = URLRequest(url: URL(string: base + "/__emit")!)
    request.httpMethod = "POST"
    let timestamp = Date().timeIntervalSince1970
    request.httpBody = JSONValue.object(["messages": [
      ["id": 3, "role": "user", "content": "continue", "timestamp": .number(timestamp)],
      ["id": 4, "role": "assistant", "content": "First answer", "timestamp": .number(timestamp)],
    ]]).data()
    _ = try await URLSession.shared.data(for: request)
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.onMac.count, 1)
    XCTAssertEqual(reopened.state.items.filter { $0.kind == .user && $0.text == "continue" }.count, 1, "receipt settlement must reuse its own stored row")
    app.chatDisappeared(reopened)
    let again = await openChat()
    try await emit("message.start", admissionID: admissionIDs[1])
    try await emit("message.complete", admissionID: admissionIDs[1], payload: ["text": "Second answer", "outcome": "completed", "status": "complete"])
    try await waitUntil("second answer rendered after a second history read") { again.state.items.contains { $0.text == "Second answer" } }
    XCTAssertEqual(again.state.items.filter { $0.kind == .user && $0.text == "continue" }.count, 2, "one history row can represent only one admission, even across navigation")
    XCTAssertTrue(again.queue.onMac.isEmpty)
    app.chatDisappeared(again)
  }

  func testActualEventPumpConsumesOnlyTheMatchingAdmission() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    for text in ["First follow-up", "Second follow-up"] {
      chat.draft = text
      await chat.send()
    }
    await chat.handOffQueue()
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 2)
    let admissionID = "admitted-" + (submissions.first?["params"]["submission_id"].stringValue ?? "")
    try await emit("message.complete", admissionID: "original-turn", payload: ["text": "Original finished"])
    try await waitUntil("original turn ended through AppModel") { !chat.isStreaming }
    try await emit("message.start", admissionID: "unrelated-background-turn")
    try await waitUntil("background turn started through AppModel") { chat.isStreaming }
    XCTAssertEqual(chat.queue.onMac.count, 2, "unrelated background work must not consume follow-ups")
    try await emit("message.complete", admissionID: "unrelated-background-turn", payload: ["text": "Background finished"])
    try await waitUntil("background turn ended") { !chat.isStreaming }
    try await emit("message.start", admissionID: admissionID)
    try await waitUntil("only the matching admission left the queue") { chat.queue.onMac.count == 1 }
    XCTAssertEqual(chat.queue.onMac.map(\.text), ["Second follow-up"])
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user && $0.text == "First follow-up" }.count, 1)
    app.chatDisappeared(chat)
  }

  func testReopeningDuringFollowUpClearsOnlyTheStartedEntry() async throws {
    let chat = await openChat()
    for text in ["First follow-up", "Second follow-up"] {
      chat.draft = text
      await chat.send()
    }
    await chat.handOffQueue()
    XCTAssertEqual(chat.queue.onMac.count, 2)
    app.chatDisappeared(chat)
    try await configure(["receipt_statuses": ["First follow-up": "started"],
                         "resume_messages": []])
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.onMac.map(\.text), ["Second follow-up"],
                   "a follow-up already running must leave the queue; later ones must stay")
    app.chatDisappeared(reopened)
  }

  func testMatchingCompletionSettlesAnAdmissionWhoseStartWasMissed() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "Start was lost during reconnect"
    await chat.send()
    await chat.handOffQueue()
    let submitted = try await calls().first { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submitted?["params"]["submission_id"].stringValue ?? "")
    try await emit("message.complete", admissionID: "original-turn", payload: ["text": "Original finished"])
    try await waitUntil("original finished") { !chat.isStreaming }
    try await emit("message.complete", admissionID: admissionID, payload: ["text": "Follow-up finished", "outcome": "completed"])
    try await waitUntil("matching completion settled its admission") { chat.queue.onMac.isEmpty }
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user && $0.text == "Start was lost during reconnect" }.count, 1)
    XCTAssertEqual(chat.state.items.filter { $0.kind == .assistant && $0.text == "Follow-up finished" }.count, 1)
    app.chatDisappeared(chat)
  }

  func testOpeningBuffersMatchingStartUntilSlowHistoryIsAdopted() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "Starts during reopen"
    await chat.send()
    await chat.handOffQueue()
    let submitted = try await calls().first { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submitted?["params"]["submission_id"].stringValue ?? "")
    app.chatDisappeared(chat)
    try await configure(["history_delay": 0.5, "final_history_delay": 0.5])
    let reopened = app.chat(profile: "selected", storedID: "fixture")
    app.chatAppeared(reopened)
    let opening = Task { await reopened.open() }
    try await waitUntil("receipt read while history is pending") {
      try await self.calls().contains { $0["method"].string == "prompt.receipt" }
    }
    XCTAssertTrue(reopened.isLoading)
    try await emit("message.complete", admissionID: "original-turn", payload: ["text": "Original finished"])
    try await emit("message.start", admissionID: admissionID)
    try await emit("message.delta", admissionID: admissionID, payload: ["text": "Early follow-up delta"])
    await opening.value
    try await emit("message.complete", admissionID: admissionID, payload: ["text": "Follow-up finished"])
    try await waitUntil("follow-up completed") { !reopened.isStreaming }
    XCTAssertTrue(reopened.queue.onMac.isEmpty, "a start between receipt read and history adoption must not be lost")
    XCTAssertEqual(reopened.state.items.filter { $0.kind == .user && $0.text == "Starts during reopen" }.count, 1)
    XCTAssertEqual(reopened.state.items.filter { $0.kind == .assistant && $0.text == "Follow-up finished" }.count, 1)
    app.chatDisappeared(reopened)
  }

  func testReplayStartSettlesOnlyItsAdmissionWhenReceiptRemainsUnknown() async throws {
    let chat = await openChat()
    for text in ["Started while away", "Still waiting"] {
      chat.draft = text
      await chat.send()
    }
    await chat.handOffQueue()
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submissions.first?["params"]["submission_id"].stringValue ?? "")
    app.chatDisappeared(chat)
    try await configure(["receipt_statuses": ["Started while away": "unknown"], "replay_events": [
      ["type": "message.start", "admission_id": .string(admissionID), "execution_generation": 1, "payload": [:]],
      ["type": "message.delta", "admission_id": .string(admissionID), "execution_generation": 1, "payload": ["text": "Working on the follow-up"]],
    ]])
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.onMac.map(\.text), ["Still waiting"], "replay must preserve the exact admission just like live delivery")
    XCTAssertEqual(reopened.state.items.filter { $0.kind == .user && $0.text == "Started while away" }.count, 1)
    XCTAssertTrue(reopened.isStreaming)
    app.chatDisappeared(reopened)
  }

  func testPausedQueueKeepsItsPhotosAndOrderAcrossNavigation() async throws {
    let chat = await openChat()
    let bytes = Data([1, 2, 3, 4])
    chat.attachments = [ComposerAttachment(kind: .image, name: "example.jpg", data: bytes, status: .ready)]
    chat.draft = "Keep this photo"
    await chat.send()
    chat.draft = "Keep this second message"
    await chat.send()
    // Stop pauses the queue even when an interrupt is refused by this fixture.
    await chat.stop()
    let ids = chat.queue.entries.map(\.id)
    app.chatDisappeared(chat)
    await Task.yield()
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.id), ids)
    XCTAssertTrue(reopened.queue.isPaused)
    XCTAssertEqual(reopened.queue.entries.first?.attachments.first?.data, bytes)
    XCTAssertTrue(reopened.draft.isEmpty, "queued messages must not be flattened into a draft")
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertTrue(submissions.isEmpty)
    app.chatDisappeared(reopened)
  }

  func testFailedHandoffStaysQueuedWithAttachmentsInsteadOfBecomingADraft() async throws {
    try await control(["gateway_running": true, "submit_error": true])
    let chat = await openChat()
    chat.draft = "Keep the failed handoff"
    chat.addFile(data: Data([9, 8, 7]), name: "example.txt", mimeType: "text/plain")
    await chat.send()
    let entryID = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "file.attach" }.count, 1)
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 1,
                   "exercise submit refusal, not an attachment-fixture error before admission")
    app.chatDisappeared(chat)
    try await Task.sleep(for: .milliseconds(50))
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.id), [entryID])
    XCTAssertEqual(reopened.queue.entries.first?.attachments.first?.data, Data([9, 8, 7]))
    XCTAssertFalse(reopened.queue.entries.first?.isDelivering ?? true)
    XCTAssertTrue(reopened.draft.isEmpty)
    app.chatDisappeared(reopened)
  }

  func testUnpausedQueueDrainsWhenReopenedAfterTheOriginalTurnEnded() async throws {
    try await control(["gateway_running": true, "submit_error": true])
    let chat = await openChat()
    chat.draft = "Retry when the chat is available"
    await chat.send()
    await chat.handOffQueue()
    app.chatDisappeared(chat)
    try await Task.sleep(for: .milliseconds(50))
    let before = try await calls().filter { $0["method"].string == "prompt.submit" }.count
    try await configure(["gateway_running": false, "submit_error": false])
    let reopened = await openChat()
    try await waitUntil("an unpaused queue in an idle reopened chat must actually send") {
      try await self.calls().filter { $0["method"].string == "prompt.submit" }.count > before
    }
    XCTAssertTrue(reopened.queue.entries.isEmpty)
    app.chatDisappeared(reopened)
  }

  func testGatewayRosterMembershipDoesNotBecomeMacOwnership() async throws {
    for status in ["starting", "idle", "working", "waiting"] {
      try await control(["active_status": .string(status), "fresh_heartbeat": true,
                         "gateway_running": .bool(status != "idle")])
      let chat = await openChat()
      XCTAssertNil(chat.owner, "gateway status \(status) is not a different owner")
      XCTAssertFalse(chat.continuesAsNewVersion, "\(status) forced an unnecessary branch")
      XCTAssertEqual(chat.liveID, "fixture", "\(status) did not attach to the shared gateway chat")
      let methods = try await calls().map { $0["method"].stringValue }
      XCTAssertTrue(methods.contains("session.resume"), "\(status) incorrectly chose read-only watching")
      app.chatDisappeared(chat)
    }
  }

  func testUnavailableRosterIsNotEvidenceOfAnExternalOwner() async throws {
    try await control(["active_error": true, "fresh_heartbeat": true])
    let chat = await openChat()
    XCTAssertNil(chat.owner)
    XCTAssertFalse(chat.continuesAsNewVersion)
    XCTAssertEqual(chat.liveID, "fixture")
    app.chatDisappeared(chat)
  }

  func testDelayedHandoffRevalidatesRemovedAndEditedEntries() async throws {
    try await configure(["submit_delay": 0.4])
    let chat = await openChat()
    for text in ["A", "B removed", "C edited"] {
      chat.draft = text
      await chat.send()
    }
    let ids = chat.queue.entries.map(\.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("A is awaiting admission") {
      try await self.calls().contains { $0["method"].string == "prompt.submit" }
    }
    // A second screen model sees and edits the shared queue while the first awaits A's ACK.
    app.chatDisappeared(chat)
    let reopened = await openChat()
    XCTAssertFalse(reopened === chat)
    reopened.deleteQueued(ids[1])
    reopened.editQueued(ids[2])
    XCTAssertEqual(reopened.draft, "C edited")
    await handoff.value
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.map { $0["params"]["text"].stringValue }, ["A"],
                   "a captured entry removed or edited on the reopened screen must never be submitted")
    app.chatDisappeared(reopened)
  }

  func testStopCancelsAdmissionsAlreadyOnMacAndKeepsThemHeldInOrder() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    for text in ["A", "B"] {
      chat.draft = text
      await chat.send()
    }
    let ids = chat.queue.entries.map(\.id)
    await chat.handOffQueue()
    XCTAssertTrue(chat.queue.entries.isEmpty)
    await chat.stop()
    try await waitUntil("Stop cancelled both admitted follow-ups") { chat.queue.onMac.isEmpty }
    XCTAssertEqual(chat.queue.entries.map(\.id), ids)
    XCTAssertTrue(chat.queue.isPaused)
    let recorded = try await calls()
    let cancels = recorded.filter { $0["method"].string == "prompt.cancel" }
    XCTAssertEqual(cancels.count, 2)
    XCTAssertEqual(cancels.map { $0["params"]["admission_id"].stringValue }, ids.map { "admitted-" + $0.uuidString.lowercased() })
    app.chatDisappeared(chat)
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.id), ids)
    XCTAssertTrue(reopened.queue.isPaused)
    app.chatDisappeared(reopened)
  }

  func testStopKeepsFIFOWhenLateAcknowledgementFollowsCompletedCancellationBatch() async throws {
    try await configure(["hold_submissions": ["B"]])
    let chat = await openChat()
    for text in ["A", "B"] {
      chat.draft = text
      await chat.send()
    }
    let ids = chat.queue.entries.map(\.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("A acknowledged and B held before its acknowledgement") {
      try await self.calls().filter { $0["method"].string == "prompt.submit" }.count == 2
    }
    XCTAssertEqual(chat.queue.onMac.map(\.text), ["A"])
    await chat.stop()
    XCTAssertTrue(chat.queue.onMac.isEmpty)
    XCTAssertEqual(chat.queue.entries.map(\.text), ["A", "B"], "A's first cancellation batch has fully settled")
    let firstBatch = try await calls()
    XCTAssertEqual(firstBatch.filter { $0["method"].string == "prompt.receipt" }.count, 1)
    try await configure(["hold_submissions": []])
    await handoff.value
    XCTAssertTrue(chat.queue.onMac.isEmpty)
    XCTAssertEqual(chat.queue.entries.map(\.id), ids, "F2: a later cancellation batch must not prepend B before A")
    XCTAssertTrue(chat.queue.isPaused)
    app.chatDisappeared(chat)
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.id), ids)
    XCTAssertTrue(reopened.queue.isPaused)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.cancel" }.count, 2)
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 2)
    app.chatDisappeared(reopened)
  }

  func testStopCancellationIncludesAnAcknowledgementArrivingDuringCancellation() async throws {
    try await configure(["submit_delay": 0.25, "cancel_delay": 0.4])
    let chat = await openChat()
    for text in ["A", "B"] {
      chat.draft = text
      await chat.send()
    }
    let ids = chat.queue.entries.map(\.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("B admission in flight while A is acknowledged") {
      try await self.calls().filter { $0["method"].string == "prompt.submit" }.count == 2
    }
    await chat.stop()
    await handoff.value
    XCTAssertTrue(chat.queue.onMac.isEmpty, "Stop must not miss B while waiting for A's cancellation")
    XCTAssertEqual(chat.queue.entries.map(\.id), ids)
    XCTAssertTrue(chat.queue.isPaused)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.cancel" }.count, 2)
    app.chatDisappeared(chat)
  }

  func testStopIntentSurvivesUnavailableCancellationAndRetriesOnReopen() async throws {
    try await configure(["cancel_error": true])
    let chat = await openChat()
    chat.draft = "Stop still applies after reconnect"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    await chat.stop()
    XCTAssertEqual(chat.queue.onMac.map(\.id), [id], "unconfirmed cancellation must remain visible")
    XCTAssertTrue(chat.queue.isPaused)
    app.chatDisappeared(chat)
    try await configure(["cancel_error": false])
    let reopened = await openChat()
    XCTAssertTrue(reopened.queue.onMac.isEmpty, "reopening must finish the retained Stop intent")
    XCTAssertEqual(reopened.queue.entries.map(\.id), [id])
    XCTAssertTrue(reopened.queue.isPaused)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 1)
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.cancel" }.count, 2)
    app.chatDisappeared(reopened)
  }

  func testStopPauseSurvivesFinalLateAcknowledgementWhenCancellationIsUnavailable() async throws {
    try await configure(["hold_submissions": ["Only pending admission"], "cancel_error": true])
    let chat = await openChat()
    chat.draft = "Only pending admission"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("final admission is awaiting acknowledgement") {
      try await self.calls().contains { $0["method"].string == "prompt.submit" }
    }
    await chat.stop()
    XCTAssertTrue(chat.queue.isPaused)
    try await configure(["hold_submissions": []])
    await handoff.value
    XCTAssertEqual(chat.queue.onMac.map(\.id), [id], "failed cancellation is not proof the admission stopped")
    XCTAssertTrue(chat.queue.isPaused, "F4: moving the last pending admission to Mac must not clear Stop's hold")
    app.chatDisappeared(chat)
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.onMac.map(\.id), [id])
    XCTAssertTrue(reopened.queue.isPaused, "the unconfirmed Stop hold must survive navigation")
    let failed = try await calls()
    XCTAssertEqual(failed.filter { $0["method"].string == "prompt.cancel" }.count, 2, "Stop intent retries, rather than being forgotten")
    XCTAssertEqual(failed.filter { $0["method"].string == "prompt.submit" }.count, 1)
    app.chatDisappeared(reopened)
    try await configure(["cancel_error": false])
    let recovered = await openChat()
    XCTAssertTrue(recovered.queue.onMac.isEmpty)
    XCTAssertEqual(recovered.queue.entries.map(\.id), [id])
    XCTAssertTrue(recovered.queue.isPaused)
    app.chatDisappeared(recovered)
  }

  func testStopCancelsLateAcknowledgementAfterNavigation() async throws {
    try await configure(["open_gate": true, "submit_delay": 0.4])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "A awaiting acknowledgement"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("submit in flight") { try await self.calls().contains { $0["method"].string == "prompt.submit" } }
    app.chatDisappeared(chat)
    let reopened = await openChat()
    await reopened.stop()
    await handoff.value
    try await waitUntil("late acknowledgement cancelled") { reopened.queue.onMac.isEmpty && reopened.queue.entries.count == 1 }
    XCTAssertEqual(reopened.queue.entries.map(\.id), [id])
    XCTAssertTrue(reopened.queue.isPaused)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.cancel" }.count, 1)
    app.chatDisappeared(reopened)
  }

  func testStopDuringDelayedHandoffHoldsRemainingEntries() async throws {
    try await configure(["submit_delay": 0.4])
    let chat = await openChat()
    for text in ["A", "B waits after Stop"] {
      chat.draft = text
      await chat.send()
    }
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("A is awaiting admission") {
      try await self.calls().contains { $0["method"].string == "prompt.submit" }
    }
    app.chatDisappeared(chat)
    let reopened = await openChat()
    XCTAssertFalse(reopened === chat)
    await reopened.stop()
    await handoff.value
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.map { $0["params"]["text"].stringValue }, ["A"])
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["A", "B waits after Stop"],
                   "Stop must also cancel and hold A when its acknowledgement arrives late")
    XCTAssertTrue(reopened.queue.onMac.isEmpty)
    XCTAssertTrue(reopened.queue.isPaused)
    app.chatDisappeared(reopened)
  }

  func testStopDuringStagingPreventsAdmission() async throws {
    try await configure(["attach_delay": 0.4])
    let chat = await openChat()
    chat.draft = "Photo not yet admitted"
    chat.attachments = [ComposerAttachment(kind: .image, name: "example.jpg", data: Data([1, 2]), status: .ready)]
    await chat.send()
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("photo staging started") {
      try await self.calls().contains { $0["method"].string == "image.attach_bytes" }
    }
    await chat.stop()
    await handoff.value
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertTrue(submissions.isEmpty, "Stop while staging must prevent the still-pending admission")
    XCTAssertEqual(chat.queue.entries.map(\.text), ["Photo not yet admitted"])
    XCTAssertFalse(chat.queue.entries.first?.isDelivering ?? true)
    app.chatDisappeared(chat)
  }

  func testDeliveringEntryCannotBeEditedOrDeleted() async throws {
    try await configure(["submit_delay": 0.4])
    let chat = await openChat()
    chat.draft = "Admission already in flight"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    let handoff = Task { await chat.handOffQueue() }
    try await waitUntil("admission is in flight") {
      try await self.calls().contains { $0["method"].string == "prompt.submit" }
    }
    chat.editQueued(id)
    chat.deleteQueued(id)
    XCTAssertEqual(chat.queue.entries.map(\.id), [id])
    XCTAssertTrue(chat.draft.isEmpty)
    await handoff.value
    XCTAssertEqual(chat.queue.onMac.map(\.id), [id])
    app.chatDisappeared(chat)
  }

  func testLostAcknowledgementReopenRecoversOriginalIdentityAndStagedPayload() async throws {
    try await configure(["submit_commit_disconnect": true, "dynamic_attachment_paths": true])
    let chat = await openChat()
    chat.draft = "One admission despite losing the ACK"
    chat.addFile(data: Data([9, 8, 7]), name: "example.txt", mimeType: "text/plain")
    chat.attachments.append(ComposerAttachment(kind: .image, name: "example.jpg", data: Data([1, 2]), status: .ready))
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    XCTAssertTrue(chat.queue.isPaused, "uncertain admission must be held, not offered to the ordinary drain")
    app.chatDisappeared(chat)
    try await configure(["gateway_running": false, "submit_commit_disconnect": false])
    let reopened = await openChat()
    try await waitUntil("reopen recovered the admission") {
      try await self.calls().filter { $0["method"].string == "prompt.submit" }.count >= 2
    }
    try await waitUntil("original entry was acknowledged") { reopened.queue.entries.isEmpty }
    await reopened.sendNow(id)
    reopened.resumeQueue()
    await reopened.handOffQueue()
    let recorded = try await calls()
    let submissions = recorded.filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 2)
    XCTAssertEqual(submissions.first?["params"], submissions.last?["params"], "recovery must replay the exact original payload and ID")
    XCTAssertEqual(submissions.last?["params"]["submission_id"].string, id.uuidString.lowercased())
    XCTAssertEqual(recorded.filter { $0["method"].string == "fixture.committed" }.count, 1, "lost ACK must not create a second admission")
    XCTAssertEqual(recorded.filter { $0["method"].string == "file.attach" }.count, 1)
    XCTAssertEqual(recorded.filter { $0["method"].string == "image.attach_bytes" }.count, 1)
    app.chatDisappeared(reopened)
  }

  func testSendNowRecoversUncertainAdmissionInsteadOfRedirecting() async throws {
    try await configure(["submit_commit_error": true])
    let chat = await openChat()
    chat.draft = "One immutable text admission"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    try await configure(["submit_commit_error": false])
    await chat.sendNow(id)
    let recorded = try await calls()
    let submissions = recorded.filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 2, "Send now must recover the prior submit, not admit or redirect new work")
    XCTAssertEqual(submissions.first?["params"], submissions.last?["params"])
    XCTAssertFalse(recorded.contains { $0["method"].string == "session.redirect" })
    XCTAssertEqual(recorded.filter { $0["method"].string == "fixture.committed" }.count, 1)
    XCTAssertEqual(chat.queue.onMac.map(\.id), [id])
    app.chatDisappeared(chat)
  }

  func testNewHandoffRecoversUncertainAdmissionWithoutRestaging() async throws {
    try await configure(["submit_commit_error": true, "dynamic_attachment_paths": true])
    let chat = await openChat()
    chat.draft = "Immutable file reference"
    chat.addFile(data: Data([9, 8, 7]), name: "example.txt", mimeType: "text/plain")
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    try await configure(["submit_commit_error": false])
    await chat.handOffQueue()
    let recorded = try await calls()
    let submissions = recorded.filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 2)
    XCTAssertEqual(submissions.first?["params"], submissions.last?["params"])
    XCTAssertEqual(recorded.filter { $0["method"].string == "file.attach" }.count, 1)
    XCTAssertEqual(recorded.filter { $0["method"].string == "fixture.committed" }.count, 1)
    XCTAssertEqual(chat.queue.onMac.map(\.id), [id])
    app.chatDisappeared(chat)
  }

  func testUncertainAdmissionIsHeldAgainstEditingDeletingAndResume() async throws {
    try await configure(["submit_commit_error": true])
    let chat = await openChat()
    chat.draft = "Hold until receipt recovery"
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    XCTAssertTrue(chat.queue.entries.first?.isAwaitingReceipt ?? false)
    XCTAssertFalse(chat.queue.entries.first?.isDelivering ?? true, "unconfirmed is a held state, not an endless active send")
    var resumedCopy = chat.queue
    resumedCopy.resume()
    XCTAssertNil(resumedCopy.next(isBusy: false), "resuming cannot make an uncertain admission ordinarily sendable")
    chat.editQueued(id)
    chat.deleteQueued(id)
    XCTAssertEqual(chat.queue.entries.map(\.id), [id])
    XCTAssertTrue(chat.draft.isEmpty)
    app.chatDisappeared(chat)
    try await configure(["gateway_running": false])
    let reopened = await openChat()
    XCTAssertFalse(reopened === chat)
    XCTAssertFalse(reopened.isStreaming)
    reopened.resumeQueue()
    await reopened.sendNow(id)
    await reopened.handOffQueue()
    XCTAssertEqual(reopened.queue.entries.map(\.id), [id], "continued ambiguous errors must not make the entry sendable")
    XCTAssertTrue(reopened.queue.isPaused)
    let recorded = try await calls()
    let submissions = recorded.filter { $0["method"].string == "prompt.submit" }
    XCTAssertGreaterThan(submissions.count, 1, "recovery must actually retry the original admission")
    XCTAssertEqual(Set(submissions.map { $0["params"]["submission_id"].stringValue }), [id.uuidString.lowercased()])
    XCTAssertTrue(submissions.allSatisfy { $0["params"] == submissions.first?["params"] })
    XCTAssertEqual(recorded.filter { $0["method"].string == "fixture.committed" }.count, 1)
    XCTAssertFalse(recorded.contains { $0["method"].string == "session.redirect" })
    app.chatDisappeared(reopened)
  }

  func testInterruptedCompletionSettlesExecutionWhenItsStartWasMissed() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "Executed but start was missed"
    await chat.send()
    await chat.handOffQueue()
    let submitted = try await calls().first { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submitted?["params"]["submission_id"].stringValue ?? "")
    try await emit("message.complete", admissionID: "original-turn", payload: ["text": "Original finished", "outcome": "completed", "status": "complete"])
    try await waitUntil("original ended") { !chat.isStreaming }
    try await emit("message.complete", admissionID: admissionID, payload: ["text": "Partial follow-up", "outcome": "cancelled", "status": "interrupted"])
    try await waitUntil("executed interrupted completion rendered") { chat.state.items.contains { $0.kind == .assistant && $0.text == "Partial follow-up" } }
    XCTAssertTrue(chat.queue.onMac.isEmpty, "an execution interruption is proof of execution even without its start")
    XCTAssertTrue(chat.queue.entries.isEmpty, "never hold and resubmit an executed interruption")
    XCTAssertEqual(chat.state.items.filter { $0.kind == .user && $0.text == "Executed but start was missed" }.count, 1)
    app.chatDisappeared(chat)
  }

  func testInterruptedReceiptAfterExecutionWhileAwayRemovesWaitingIndicator() async throws {
    let chat = await openChat()
    chat.draft = "Ran then stopped while away"
    await chat.send()
    await chat.handOffQueue()
    let submitted = try await calls().first { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submitted?["params"]["submission_id"].stringValue ?? "")
    app.chatDisappeared(chat)
    XCTAssertNil(app.openChat)
    try await emit("message.start", admissionID: admissionID)
    let client = try XCTUnwrap(app.client)
    try await client.interrupt(liveID: "fixture", profile: "selected")
    let receipt = try await client.receipt(liveID: "fixture", profile: "selected", admissionID: admissionID)
    XCTAssertEqual(receipt["status"].string, "terminal")
    XCTAssertEqual(receipt["outcome"].string, "interrupted", "receipts retain interrupted; only live completion maps it to cancelled")
    let reopened = await openChat()
    XCTAssertTrue(reopened.queue.onMac.isEmpty, "F3: a known executed terminal receipt is not still waiting")
    XCTAssertTrue(reopened.queue.entries.isEmpty, "interrupted execution must not return as an unstarted cancellation")
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 1)
    app.chatDisappeared(reopened)
  }

  func testUnknownReceiptStatusAndTerminalOutcomeStayVisibleWithoutResubmission() async throws {
    let chat = await openChat()
    for text in ["Unknown status", "Unknown terminal outcome"] {
      chat.draft = text
      await chat.send()
    }
    await chat.handOffQueue()
    let ids = chat.queue.onMac.map(\.id)
    app.chatDisappeared(chat)
    try await configure(["gateway_running": false,
      "receipt_statuses": ["Unknown status": "unknown", "Unknown terminal outcome": "terminal"],
      "receipt_outcome": "unknown"])
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.onMac.map(\.id), ids, "unknown is not evidence that an admission ran")
    XCTAssertTrue(reopened.queue.entries.isEmpty)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 2)
    app.chatDisappeared(reopened)
  }

  func testQueuedCancellationDoesNotFinishTheUnrelatedRunningTurn() async throws {
    try await configure(["open_gate": true])
    try await app.connect(to: base)
    let chat = await openChat()
    chat.draft = "A cancelled before starting"
    await chat.send()
    await chat.handOffQueue()
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    let admissionID = "admitted-" + (submissions.first?["params"]["submission_id"].stringValue ?? "")
    chat.draft = "B must not drain while original runs"
    await chat.send()
    try await emit("message.delta", admissionID: "original-turn", payload: ["text": "Original still working"])
    try await waitUntil("original delta delivered") { chat.state.items.contains { $0.text == "Original still working" } }
    let client = try XCTUnwrap(app.client)
    _ = try await client.rpc.call("prompt.cancel", ["session_id": "fixture", "profile": "selected", "admission_id": .string(admissionID)])
    try await waitUntil("cancelled entry returned held") { chat.queue.entries.map(\.text) == ["A cancelled before starting", "B must not drain while original runs"] }
    XCTAssertTrue(chat.isStreaming, "queued cancellation is not completion of the original execution")
    XCTAssertTrue(chat.queue.isPaused)
    XCTAssertTrue(chat.queue.onMac.isEmpty)
    let recorded = try await calls()
    XCTAssertEqual(recorded.filter { $0["method"].string == "prompt.submit" }.count, 1)
    XCTAssertTrue(chat.state.items.contains { $0.text == "Original still working" && $0.isStreaming })
    app.chatDisappeared(chat)
  }

  func testConfirmedCancellationPreservesEntryButRenewsAdmissionOnResume() async throws {
    let chat = await openChat()
    chat.draft = "Try this cancelled follow-up again"
    chat.addFile(data: Data([9, 8, 7]), name: "example.txt", mimeType: "text/plain")
    await chat.send()
    let id = try XCTUnwrap(chat.queue.entries.first?.id)
    await chat.handOffQueue()
    app.chatDisappeared(chat)
    let firstCalls = try await calls()
    let text = try XCTUnwrap(firstCalls.first { $0["method"].string == "prompt.submit" }?["params"]["text"].string)
    try await configure(["receipt_statuses": .object([text: "terminal"]), "receipt_outcome": "cancelled"])
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.id), [id], "the visible entry keeps its identity and attachments")
    XCTAssertEqual(reopened.queue.entries.first?.attachments.first?.data, Data([9, 8, 7]))
    XCTAssertTrue(reopened.queue.isPaused)
    try await configure(["receipt_statuses": [:]])
    reopened.resumeQueue()
    await reopened.handOffQueue()
    let recorded = try await calls()
    let submissions = recorded.filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 2)
    XCTAssertNotEqual(submissions.first?["params"]["submission_id"], submissions.last?["params"]["submission_id"],
                      "a terminal cancelled admission cannot run again under its old dedup identity")
    XCTAssertEqual(recorded.filter { $0["method"].string == "fixture.committed" }.count, 2)
    XCTAssertEqual(reopened.queue.onMac.map(\.id), [id])
    app.chatDisappeared(reopened)
  }

  func testCancelledAdmissionsReturnAsOneFIFOOrderedBatch() async throws {
    let chat = await openChat()
    for text in ["A", "B", "C"] {
      chat.draft = text
      await chat.send()
    }
    let ids = chat.queue.entries.map(\.id)
    await chat.handOffQueue()
    XCTAssertEqual(chat.queue.onMac.map(\.id), ids)
    chat.draft = "D waits locally"
    await chat.send()
    await chat.stop()
    app.chatDisappeared(chat)
    try await configure(["gateway_running": false,
                         "receipt_statuses": ["A": "terminal", "B": "terminal", "C": "terminal"],
                         "receipt_outcome": "cancelled"])
    let reopened = await openChat()
    XCTAssertEqual(reopened.queue.entries.map(\.text), ["A", "B", "C", "D waits locally"],
                   "return all cancelled admissions ahead of local work without reversing them")
    XCTAssertEqual(Array(reopened.queue.entries.prefix(3).map(\.id)), ids)
    XCTAssertTrue(reopened.queue.onMac.isEmpty)
    XCTAssertTrue(reopened.queue.isPaused)
    app.chatDisappeared(reopened)
  }

  func testOverlappingHandoffsSubmitEachFollowUpOnlyOnce() async throws {
    try await control(["gateway_running": true, "submit_delay": 0.4])
    let chat = await openChat()
    chat.draft = "Exactly once during overlapping navigation and background"
    await chat.send()
    let first = Task { await chat.handOffQueue() }
    try await waitUntil("first submission started") {
      try await self.calls().contains { $0["method"].string == "prompt.submit" }
    }
    let second = Task { await chat.handOffQueue() }
    await first.value
    await second.value
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 1, "navigation and background submitted the same follow-up twice")
    XCTAssertEqual(chat.queue.onMac.count, 1)
    app.chatDisappeared(chat)
  }

  func testHandedOffQueueSurvivesLeavingAndReopeningChat() async throws {
    let chat = await openChat()
    XCTAssertTrue(chat.isStreaming)
    chat.draft = "Follow-up stays visible"
    await chat.send()
    let entryID = try XCTUnwrap(chat.queue.entries.first?.id)
    app.chatDisappeared(chat)
    try await waitUntil("handoff was acknowledged") { chat.queue.onMac.count == 1 }

    let reopened = await openChat()
    XCTAssertFalse(reopened === chat, "navigation really replaced the view's model")
    XCTAssertEqual(reopened.queue.onMac.map(\.id), [entryID], "accepted follow-up disappeared on navigation")
    XCTAssertEqual(reopened.queue.onMac.map(\.text), ["Follow-up stays visible"])
    XCTAssertTrue(reopened.queue.isShowing)
    XCTAssertFalse(reopened.continuesAsNewVersion)
    XCTAssertTrue(reopened.draft.isEmpty)
    let submissions = try await calls().filter { $0["method"].string == "prompt.submit" }
    XCTAssertEqual(submissions.count, 1)
    app.chatDisappeared(reopened)
  }
}
