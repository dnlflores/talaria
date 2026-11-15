import XCTest

/// Offline checks of Try again in the production chat, transcript and composer: the long-press
/// menu on the newest reply and message, and `/retry` typed in the composer. `--scroll-preview`
/// stands in for the Mac: Try again takes the preview's newest turn off and streams a canned
/// reply, so no sign-in or gateway is needed.
@MainActor
final class RetryTests: XCTestCase {
  private var app: XCUIApplication!
  private var input: XCUIElement { app.textViews["composer.input"].firstMatch }
  private let question = "Inspect the latest change."
  private let oldReply = "Latest reply. Everything is up to date."

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--short-chat", "--slash-preview"]
    if let appearance = ProcessInfo.processInfo.environment["TALARIA_UITEST_APPEARANCE"] {
      app.launchEnvironment["TALARIA_PREVIEW_APPEARANCE"] = appearance
    }
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

  private func texts(containing words: String) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words))
  }

  private var questionBubbles: XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label == %@", question))
  }

  private func waitFor(_ predicate: String, _ element: Any, timeout: Double = 10) {
    let done = expectation(for: NSPredicate(format: predicate), evaluatedWith: element)
    wait(for: [done], timeout: timeout)
  }

  /// The old reply goes, the same question shows once, and a fresh reply streams in under it.
  private func expectFreshReply(_ name: String) {
    waitFor("count == 0", texts(containing: oldReply))
    XCTAssertTrue(texts(containing: "A fresh answer").firstMatch.waitForExistence(timeout: 10), "a new reply arrives")
    waitFor("count == 1", questionBubbles)
    shoot(name)
  }

  private func openMenu(on element: XCUIElement) -> XCUIElement {
    let item = app.buttons["Try again"]
    for _ in 0..<3 where !item.exists {
      element.press(forDuration: 1.2)
      _ = item.waitForExistence(timeout: 3)
    }
    // The menu animates in; a tap before it settles can be lost.
    waitFor("hittable == true", item, timeout: 3)
    Thread.sleep(forTimeInterval: 0.5)
    return item
  }

  /// Picks Try again and waits for the menu to close before anything else is touched.
  private func pick(_ item: XCUIElement) {
    item.tap()
    waitFor("exists == false", item, timeout: 5)
  }

  func testTryAgainFromTheLastReply() {
    app.launch()
    let reply = app.descendants(matching: .any).matching(identifier: "transcript.answer")
      .matching(NSPredicate(format: "label CONTAINS %@", oldReply)).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 15), "the preview's reply")
    // `/retry` waits in the composer, to be sent while the new reply runs.
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("/retry")
    let item = openMenu(on: reply)
    XCTAssertTrue(item.exists, "the newest reply offers Try again")
    XCTAssertTrue(app.buttons["Copy"].exists, "and Copy")
    shoot("retry-menu-reply")
    pick(item)

    // While the new reply streams, sending /retry says to wait instead of queuing it.
    let queue = app.buttons["Queue"]
    XCTAssertTrue(queue.waitForExistence(timeout: 5), "the reply is running")
    queue.tap()
    let waiting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hermes is still replying'")).firstMatch
    XCTAssertTrue(waiting.waitForExistence(timeout: 5), "a /retry sent while the reply runs says to wait")
    shoot("retry-while-running")
    expectFreshReply("retry-reply-done")
  }

  func testTryAgainFromTheNewestMessage() {
    app.launch()
    let bubble = questionBubbles.firstMatch
    XCTAssertTrue(bubble.waitForExistence(timeout: 15))
    let item = openMenu(on: bubble)
    XCTAssertTrue(item.exists, "the newest message offers Try again")
    shoot("retry-menu-message")
    pick(item)
    expectFreshReply("retry-message-done")
  }

  func testSlashRetryInTheComposer() {
    app.launch()
    XCTAssertTrue(input.waitForExistence(timeout: 15))
    XCTAssertTrue(texts(containing: oldReply).firstMatch.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("/retry")
    app.buttons["Send"].tap()
    expectFreshReply("retry-slash-done")
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label == '/retry'")).count, 0,
      "/retry is not a message to the model")
  }

  func testOlderMessagesOfferNoTryAgain() {
    app.launchArguments = ["--scroll-preview", "--slash-preview"]
    app.launch()
    let older = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'transcript.user' AND label == 'Earlier question 8'")).firstMatch
    XCTAssertTrue(older.waitForExistence(timeout: 15))
    for _ in 0..<8 where !(older.isHittable && app.frame.insetBy(dx: 0, dy: 120).contains(older.frame)) {
      app.swipeDown(velocity: .slow)
    }
    older.press(forDuration: 1.2)
    XCTAssertFalse(app.buttons["Try again"].waitForExistence(timeout: 2), "only the newest turn is offered")
    shoot("retry-older-message")
  }
}
