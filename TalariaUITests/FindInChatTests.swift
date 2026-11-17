import XCTest

/// Offline Find in chat on the `--scroll-preview` transcript. `--older-pages` puts forty older turns
/// on the stand-in "Mac", read as the chat is searched or scrolled up, slowed by
/// `TALARIA_UITEST_PAGE_DELAY`. Only two of their messages mention "zephyr", both older than
/// anything the chat opens with; a step's output mentions it too, which Find leaves out.
@MainActor
final class FindInChatTests: XCTestCase {
  private var app: XCUIApplication!
  private var field: XCUIElement { app.textFields["find.field"] }
  private var count: XCUIElement { app.staticTexts["find.count"] }
  private var older: XCUIElement { app.buttons["find.previous"] }
  private var newer: XCUIElement { app.buttons["find.next"] }
  private var latest: XCUIElement { app.staticTexts["Latest reply. Everything is up to date."] }
  private let newestMatch = "What changed in zephyr since then?"
  private let oldestMatch = "The Zéphyr build shipped on Tuesday."

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--older-pages"]
    app.launchEnvironment["TALARIA_UITEST_PAGE_DELAY"] = "2.5"
    // The first read of the older messages fails (no connection), for the retry test.
    if name.contains("TriedAgain") { app.launchEnvironment["TALARIA_UITEST_HISTORY_FAILS"] = "1" }
    // Screenshot runs: `TALARIA_UITEST_LANDSCAPE=1`, `TALARIA_UITEST_APPEARANCE=light`,
    // `TALARIA_UITEST_HIGHLIGHT_HOLD=<seconds>` (keeps the outline for the shots).
    let environment = ProcessInfo.processInfo.environment
    if let appearance = environment["TALARIA_UITEST_APPEARANCE"] { app.launchEnvironment["TALARIA_PREVIEW_APPEARANCE"] = appearance }
    if let hold = environment["TALARIA_UITEST_HIGHLIGHT_HOLD"] { app.launchEnvironment["TALARIA_UITEST_HIGHLIGHT_HOLD"] = hold }
    XCUIDevice.shared.orientation = environment["TALARIA_UITEST_LANDSCAPE"] == "1" ? .landscapeLeft : .portrait
    app.launch()
    XCTAssertTrue(latest.waitForExistence(timeout: 10))
  }

  private func shoot(_ name: String) {
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

  private func openFindFromMenu() {
    // A toast can swallow the first tap on the title bar; retry until the item shows.
    let item = app.buttons["Find in chat"]
    for _ in 0..<3 where !item.exists {
      app.buttons["More"].tap()
      _ = item.waitForExistence(timeout: 2)
    }
    XCTAssertTrue(item.exists)
    item.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 3))
  }

  /// Polls often: an expectation looks about once a second, and the outline lasts two.
  private func waitForCount(_ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if count.exists, count.label == label { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTFail("the count never read \"\(label)\" (last: \"\(count.exists ? count.label : "none")\")", file: file, line: line)
  }

  private struct Reading {
    var match: CGRect
    /// The bottom of the title bar, or of the find bar under it.
    var top: CGFloat
    var composer: CGRect
    var screen: CGRect
  }

  /// One consistent reading of where the matched message, the bars and the composer are.
  private func read(_ text: String) -> Reading? {
    guard let root = try? app.snapshot() else { return nil }
    var match: CGRect?
    var top: CGFloat = 0
    var composer: CGRect?
    var stack: [any XCUIElementSnapshot] = [root]
    while let node = stack.popLast() {
      if node.identifier.hasPrefix("find.") || node.elementType == .navigationBar { top = max(top, node.frame.maxY) }
      if node.identifier == "composer.input" { composer = node.frame }
      if node.elementType == .staticText, node.label.contains(text) { match = node.frame }
      stack.append(contentsOf: node.children)
    }
    guard let match, let composer else { return nil }
    return Reading(match: match, top: top, composer: composer, screen: root.frame)
  }

  /// Waits for the scroll to the match to finish, then asserts from one snapshot that the matched
  /// message is on screen, below the find bar and above the composer.
  private func assertInView(_ text: String, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
    var last: CGRect?
    var reading: Reading?
    for _ in 0..<40 {
      reading = read(text)
      if let frame = reading?.match, frame == last { break }
      last = reading?.match
      Thread.sleep(forTimeInterval: 0.25)
    }
    guard let reading else { return XCTFail("\(moment): \"\(text)\" is not in the transcript", file: file, line: line) }
    let match = reading.match
    XCTAssertTrue(reading.screen.contains(match), "\(moment): \(match) is off screen \(reading.screen)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(match.minY, reading.top - 1, "\(moment): \(match) is under the bars (\(reading.top))", file: file, line: line)
    XCTAssertLessThanOrEqual(match.maxY, reading.composer.minY + 1, "\(moment): \(match) is under the composer \(reading.composer)", file: file, line: line)
  }

  func testFindsOlderMessagesAndStepsThroughThem() {
    XCTAssertFalse(app.staticTexts[newestMatch].exists, "the match must start on the Mac, not on the phone")
    openFindFromMenu()
    XCTAssertTrue(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "the field takes the cursor")
    shoot("find-bar-open")
    field.typeText("ZEPHYR")
    XCTAssertTrue(count.waitForExistence(timeout: 3))
    // Read from the "Mac" first, then the newest match is loaded and shown.
    waitForCount("Searching...", timeout: 5)
    shoot("find-searching")
    waitForCount("1 of 2")
    XCTAssertTrue(app.staticTexts[newestMatch].waitForExistence(timeout: 20))
    assertInView(newestMatch, "the newest match")
    shoot("find-newest-match")

    older.tap()
    waitForCount("2 of 2")
    XCTAssertTrue(app.staticTexts[oldestMatch].waitForExistence(timeout: 20), "stepping on loads the pages down to the match")
    Thread.sleep(forTimeInterval: 0.5)
    shoot("find-oldest-match-highlighted")
    assertInView(oldestMatch, "the oldest match")
    XCTAssertFalse(older.isEnabled, "nothing is older than the oldest match")

    newer.tap()
    waitForCount("1 of 2")
    Thread.sleep(forTimeInterval: 0.4)
    shoot("find-newest-match-highlighted")
    assertInView(newestMatch, "back to the newest match")
    XCTAssertFalse(newer.isEnabled, "nothing is newer than the newest match")

    // Return in the field goes on to the next match in the count.
    field.typeText("\n")
    waitForCount("2 of 2")
    assertInView(oldestMatch, "Return steps on")

    app.buttons["find.done"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 3))
    assertInView(oldestMatch, "after Done the view stays where it was")
    shoot("find-done")
    let jump = app.buttons["Jump to latest"]
    XCTAssertTrue(jump.waitForExistence(timeout: 3))
    jump.tap()
    XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
    XCTAssertTrue(latest.isHittable, "Jump to latest still goes back down")
  }

  func testNoMatchesAndCommandF() {
    // A hardware keyboard's Cmd-F opens the bar, as on the Mac. Sent again if the first press
    // arrived before the chat was ready for keys.
    for _ in 0..<3 where !field.exists {
      app.typeKey("f", modifierFlags: .command)
      _ = field.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(field.exists)
    field.typeText("quokka")
    waitForCount("No matches")
    XCTAssertFalse(older.isEnabled)
    XCTAssertFalse(newer.isEnabled)
    shoot("find-no-matches")
    app.buttons["find.done"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 3))
    XCTAssertTrue(latest.isHittable, "closing with no match leaves the chat where it was")
  }

  func testAFailedSearchOfOlderMessagesSaysSoAndCanBeTriedAgain() {
    openFindFromMenu()
    field.typeText("zephyr")
    // Nothing on the phone matches, and the older messages could not be read: not "No matches".
    waitForCount("Older not searched")
    let retry = app.buttons["find.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 3))
    // The failure's toast covers the bar for about three seconds.
    Thread.sleep(forTimeInterval: 3.8)
    XCTAssertTrue(retry.exists, "still offered once the toast has gone")
    shoot("find-older-not-searched")
    // Tap until the read starts, in case a toast still swallows the first tap.
    for _ in 0..<5 where retry.exists {
      retry.tap()
      Thread.sleep(forTimeInterval: 1)
    }
    XCTAssertFalse(retry.exists, "the retry button goes once the read starts")
    waitForCount("1 of 2")
    XCTAssertTrue(app.staticTexts[newestMatch].waitForExistence(timeout: 20))
    assertInView(newestMatch, "the newest match after trying again")
    shoot("find-retried")
  }
}
