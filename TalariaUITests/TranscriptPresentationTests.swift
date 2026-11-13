import XCTest

/// Offline, DEBUG-only fixture; never opens a gateway or creates a conversation.
@MainActor
final class TranscriptPresentationTests: XCTestCase {
  func testOfflineHierarchyAndToolInspectionInEveryTheme() throws {
    continueAfterFailure = false
    for family in ["standard", "t3Chat", "grove", "ocean", "ember", "iris"] {
      for mode in ["light", "dark"] {
        let app = XCUIApplication()
        app.launchArguments = ["--transcript-preview"]
        app.launchEnvironment["TALARIA_PREVIEW_THEME"] = family
        app.launchEnvironment["TALARIA_PREVIEW_APPEARANCE"] = mode
        app.launch()
        let thinking = app.staticTexts["Thinking"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["I'll inspect the file before making a change."].exists)
        let tool = app.buttons["transcript.tool.preview-read"]
        XCTAssertTrue(tool.exists)
        XCTAssertGreaterThanOrEqual(tool.frame.height, 44)
        XCTAssertEqual(app.buttons["transcript.tool.preview-running"].value as? String, "Running")
        XCTAssertEqual(app.buttons["transcript.tool.preview-error"].value as? String, "Failed")
        XCTAssertTrue((tool.value as? String)?.contains("Completed in") == true)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "transcript-\(family)-\(mode)"
        shot.lifetime = .keepAlways
        add(shot)
        tool.tap()
        XCTAssertTrue(app.staticTexts["INPUT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OUTPUT"].exists)
        app.buttons["Done"].tap()
        let work = app.buttons["transcript.work"]
        work.tap()
        XCTAssertFalse(thinking.exists)
        XCTAssertFalse(tool.exists)
        work.tap()
        XCTAssertTrue(thinking.waitForExistence(timeout: 3))
        app.terminate()
      }
    }
  }
}
