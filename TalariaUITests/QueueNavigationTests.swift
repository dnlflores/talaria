import XCTest

/// Local-only end-to-end regression. Run with TalariaQueueTests/run-tests.py --ui.
@MainActor
final class QueueNavigationTests: XCTestCase {
  private let base = "http://127.0.0.1:19129"
  private var app: XCUIApplication!

  private func post(_ path: String, _ object: [String: Any]) async throws {
    var request = URLRequest(url: URL(string: base + path)!)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: object)
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }

  private func metrics() async throws -> [[String: Any]] {
    let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/__metrics")!)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["calls"] as? [[String: Any]] ?? []
  }

  private func shoot(_ name: String) throws {
    let image = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let directory = ProcessInfo.processInfo.environment["TALARIA_QUEUE_SHOTS"] {
      let folder = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
  }

  func testFollowUpRemainsVisibleAcrossNavigationWithoutMacOwnerBanner() async throws {
    try await post("/__control", ["open_gate": true, "gateway_running": true,
                                  "active_status": "starting", "fresh_heartbeat": true])
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = base
    app.launchEnvironment["TALARIA_SIGNIN_FILE"] = "/fixture/no-signin.json"
    app.launchEnvironment["TALARIA_REMEMBER_SIGNIN_FILE"] = "0"
    app.launchEnvironment["TALARIA_OPEN_CHAT"] = "selected/fixture"
    if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    app.launch()
    defer {
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
    let input = app.textViews["composer.input"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 20))
    let queueButton = app.buttons["Queue"]
    input.tap()
    input.typeText("Keep my queued follow-up when I return")
    XCTAssertTrue(queueButton.waitForExistence(timeout: 10))
    queueButton.tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "queue.row").firstMatch.waitForExistence(timeout: 5))
    try shoot("queue-before-navigation")

    if app.buttons["area.agents"].exists {
      // Side dock: another area replaces the open chat; Chats brings back the list.
      app.openAgents()
      XCTAssertFalse(input.waitForExistence(timeout: 3) && input.isHittable, "the chat is still open")
      app.openChats()
    } else {
      let back = app.navigationBars.buttons["BackButton"]
      if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'session.row' AND label CONTAINS 'Queue navigation fixture'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    let onMac = app.descendants(matching: .any).matching(identifier: "queue.onMac").firstMatch
    XCTAssertTrue(onMac.waitForExistence(timeout: 10), "queued follow-up disappeared after navigation")
    XCTAssertTrue(onMac.label.contains("Keep my queued follow-up"))
    let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sending continues it as a new version'"))
    XCTAssertEqual(warning.count, 0, "Talaria misclassified its own chat as Mac-owned")
    let calls = try await metrics()
    let submissions = calls.filter { $0["method"] as? String == "prompt.submit" }
    XCTAssertEqual(submissions.count, 1, "navigation duplicated the handoff")
    XCTAssertGreaterThanOrEqual(calls.filter { $0["method"] as? String == "session.resume" }.count, 2,
                                "the test must really reattach after leaving")
    try shoot("queue-after-reopening")

    let params = try XCTUnwrap(submissions.first?["params"] as? [String: Any])
    let submissionID = try XCTUnwrap(params["submission_id"] as? String)
    let admissionID = "admitted-" + submissionID
    let frames: [[String: Any]] = [
      ["jsonrpc": "2.0", "method": "event", "params": ["type": "message.complete", "session_id": "fixture", "admission_id": "original", "payload": ["text": "Original reply finished"]]],
      ["jsonrpc": "2.0", "method": "event", "params": ["type": "message.start", "session_id": "fixture", "admission_id": admissionID, "payload": [:]]],
      ["jsonrpc": "2.0", "method": "event", "params": ["type": "message.delta", "session_id": "fixture", "admission_id": admissionID, "payload": ["text": "Follow-up answered"]]],
      ["jsonrpc": "2.0", "method": "event", "params": ["type": "message.complete", "session_id": "fixture", "admission_id": admissionID, "payload": ["text": "Follow-up answered"]]],
    ]
    try await post("/__emit", ["frames": frames])
    XCTAssertTrue(onMac.waitForNonExistence(timeout: 10))
    let user = app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label CONTAINS 'Keep my queued follow-up'"))
    XCTAssertTrue(user.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(user.count, 1)
    let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'transcript.answer' AND label CONTAINS 'Follow-up answered'")).firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    try shoot("queue-follow-up-delivered-once")
  }
}
