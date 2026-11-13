import XCTest

@MainActor
final class BackgroundWorkTests: XCTestCase {
  func testTasksRemainVisibleWhileChatIsIdleAndRecoverAfterUnavailableStatus() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--background-preview"]
    app.launch()
    XCTAssertTrue(app.staticTexts["The reply is finished. Background tasks continue below."].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["background.summary"].label, "Background work · 2 running")
    XCTAssertTrue(app.buttons["background.row.agent:preview-agent"].exists)
    XCTAssertTrue(app.buttons["background.row.process:preview-process"].exists)
    shot("background-running-main-idle")

    app.buttons["background.preview.offline"].tap()
    XCTAssertTrue(app.buttons["background.summary"].label.contains("status unavailable"))
    XCTAssertTrue(app.buttons["background.row.agent:preview-agent"].exists)
    XCTAssertTrue(app.staticTexts["Status unavailable. Last checked: 2 running. Retrying…"].exists)
    shot("background-status-unavailable")

    app.buttons["background.preview.reconnect"].tap()
    XCTAssertEqual(app.buttons["background.summary"].label, "Background work · 2 running")
    app.buttons["background.preview.finish"].tap()
    XCTAssertEqual(app.buttons["background.summary"].label, "Background work · 0 running")
    app.buttons["background.summary"].tap()
    XCTAssertTrue(app.buttons["background.row.agent:preview-agent"].label.contains("No longer running"))
    XCTAssertTrue(app.buttons["background.row.process:preview-process"].label.contains("Completed"))
    let failed = app.buttons["background.row.process:preview-failed"]
    XCTAssertTrue(failed.label.contains("Failed"))
    let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: failed)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    shot("background-finished-and-failed")

    failed.tap()
    XCTAssertTrue(app.staticTexts["Exit code: 1"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["swift test --filter ExampleTests"].exists)
    shot("background-command-details")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["background.summary"].exists)
  }

  func testOpenTaskDetailUpdatesFromRunningToFailed() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--background-preview"]
    app.launch()
    let schedule = app.buttons["background.preview.schedule-failure"]
    XCTAssertTrue(schedule.waitForExistence(timeout: 10))
    schedule.tap()
    app.buttons["background.row.process:preview-process"].tap()
    let detail = app.scrollViews.containing(.staticText, identifier: "swift test").firstMatch
    XCTAssertTrue(detail.staticTexts["Running"].waitForExistence(timeout: 3))
    XCTAssertTrue(detail.staticTexts["swift test"].exists)

    XCTAssertTrue(detail.staticTexts["Failed"].waitForExistence(timeout: 12), "the open sheet must reflect the next poll without being reopened")
    XCTAssertTrue(detail.staticTexts["Exit code: 7"].exists, "show the current API exit code")
    XCTAssertFalse(detail.staticTexts["Running"].exists)
    shot("background-open-detail-failed")
    app.buttons["Done"].tap()
    app.buttons["background.summary"].tap()
    XCTAssertTrue(app.buttons["background.row.process:preview-process"].label.contains("Failed"))
  }

  func testOpenTaskDetailMarksLastKnownStatusUnavailableAfterPollFailure() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--background-preview"]
    app.launch()
    let schedule = app.buttons["background.preview.schedule-unavailable"]
    XCTAssertTrue(schedule.waitForExistence(timeout: 10))
    schedule.tap()
    app.buttons["background.row.process:preview-process"].tap()
    let detail = app.scrollViews.containing(.staticText, identifier: "swift test").firstMatch
    XCTAssertTrue(detail.staticTexts["Running"].waitForExistence(timeout: 3))

    XCTAssertTrue(detail.staticTexts["Status unavailable"].waitForExistence(timeout: 12), "a failed poll must invalidate live status in the open sheet")
    XCTAssertTrue(detail.staticTexts["Last checked: Running"].exists, "retain the explicitly last-known outcome, not an invented success")
    XCTAssertFalse(detail.staticTexts["Running"].exists, "do not present last-known status as current")
    XCTAssertTrue(detail.staticTexts["swift test"].exists, "retain the complete command during an outage")
    XCTAssertFalse(detail.staticTexts["Completed"].exists)
    shot("background-open-detail-unavailable")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["background.summary"].label.contains("status unavailable"))
  }

  private func shot(_ name: String) {
    // Assertions above observe state; let the panel's 0.18s disclosure animation finish before capture.
    Thread.sleep(forTimeInterval: 0.3)
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let path = ProcessInfo.processInfo.environment["TALARIA_UITEST_SHOTS"] {
      let directory = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
  }
}
