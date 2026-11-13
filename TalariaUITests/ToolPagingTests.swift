import XCTest

/// Production layout, work-log rows and inspector, without network or credentials.
@MainActor
final class ToolPagingTests: XCTestCase {
  func testCommentaryStaysVisibleAndToolCallsLoadTwentyAtATime() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--transcript-preview", "--many-tools"]
    app.launch()
    let before = app.staticTexts["I will inspect the files."]
    let after = app.staticTexts["The checks are complete."]
    XCTAssertTrue(before.waitForExistence(timeout: 10))
    XCTAssertTrue(after.exists, "commentary after calls is not hidden in the log")
    XCTAssertTrue(app.staticTexts["All 45 files checked."].exists)
    XCTAssertFalse(app.buttons["transcript.tool.page-1"].exists)
    let log = app.buttons.matching(identifier: "transcript.work").matching(NSPredicate(format: "label == '45 tools'")).firstMatch
    log.tap()
    XCTAssertTrue(app.buttons["transcript.tool.page-1"].exists)
    XCTAssertTrue(app.buttons["transcript.tool.page-20"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.page-21"].exists)
    XCTAssertTrue(before.exists)
    XCTAssertTrue(after.exists)
    let more = app.buttons["transcript.tools.more"]
    let scroll = app.scrollViews.firstMatch
    func reach(_ element: XCUIElement, upward: Bool = true) {
      for _ in 0..<18 where !element.isHittable {
        if upward { scroll.swipeUp() } else { scroll.swipeDown() }
      }
      XCTAssertTrue(element.isHittable)
    }
    func shot(_ name: String) {
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
    reach(more)
    XCTAssertTrue(more.label.contains("20 more tool calls (25 remaining)"))
    shot("tools-first-20")
    more.tap()
    XCTAssertTrue(app.buttons["transcript.tool.page-40"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.page-41"].exists)
    reach(more)
    XCTAssertTrue(more.label.contains("5 more tool calls (5 remaining)"))
    shot("tools-first-40")
    more.tap()
    XCTAssertTrue(app.buttons["transcript.tool.page-45"].exists)
    XCTAssertFalse(more.exists)
    let last = app.buttons["transcript.tool.page-45"]
    reach(last)
    shot("tools-all-45")
    last.tap()
    XCTAssertTrue(app.staticTexts["OUTPUT"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Recorded output for call 45."].exists)
    app.buttons["Done"].tap()
    reach(log, upward: false)
    log.tap()
    XCTAssertFalse(app.buttons["transcript.tool.page-1"].exists)
    XCTAssertTrue(before.isHittable)
    XCTAssertTrue(after.isHittable)
    shot("commentary-outside-collapsed-tools")
    log.tap()
    XCTAssertTrue(app.buttons["transcript.tool.page-20"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.page-21"].exists, "reopening starts with a bounded page")
  }

  func testLoadMoreInTheProductionTranscriptKeepsTheReaderInPlace() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--short-chat", "--many-tools"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Latest reply. Everything is up to date."].waitForExistence(timeout: 10))
    let scroll = app.scrollViews["transcript.scroll"]
    app.buttons["transcript.work"].firstMatch.tap()
    XCTAssertTrue(app.buttons["transcript.tool.scroll-page-20"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.scroll-page-21"].exists)
    let more = app.buttons["transcript.tools.more"]
    for _ in 0..<12 {
      if more.isHittable { break }
      scroll.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(more.isHittable)
    let watched = app.buttons["transcript.tool.scroll-page-20"]
    let before = watched.frame.minY
    XCTAssertTrue(watched.isHittable, "watch a row beside Load more, not an off-screen row")
    more.tap()
    XCTAssertTrue(app.buttons["transcript.tool.scroll-page-40"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.scroll-page-41"].exists)
    XCTAssertLessThan(abs(watched.frame.minY - before), 30,
                      "revealing more calls pulled the reader down to the newest reply")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "production-load-more-keeps-place"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
