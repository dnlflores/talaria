import XCTest

/// Offline checks of `/btw` and `/bg` in the production chat, transcript and composer.
/// `--slash-preview` starts them without a Mac and plays each answer back through the real event
/// handling (delivered twice, as a reconnect can); `--live-turns` streams a reply meanwhile.
@MainActor
final class SideQuestionTests: XCTestCase {
  private var app: XCUIApplication!
  private var input: XCUIElement { app.textViews["composer.input"].firstMatch }
  private var notices: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "transcript.sideNotice") }
  private var cards: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "transcript.side") }
  private var failedCards: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "transcript.side.failed") }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--short-chat", "--slash-preview"]
    app.launchEnvironment["TALARIA_SIDE_PREVIEW_DELAY"] = "2"
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

  private func startTyping() {
    app.launch()
    XCTAssertTrue(input.waitForExistence(timeout: 15), "composer input")
    input.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard")
  }

  private func type(_ text: String) {
    if !app.keyboards.firstMatch.exists { input.tap() }
    input.typeText(text)
  }

  /// Sends what is typed. `/btw` and `/bg` never queue, so the button says Send even mid-reply.
  /// A freshly booted iPad simulator can drop the first tap after typing (the words stay in the
  /// composer); one more tap then sends them.
  private func send() {
    let button = app.buttons["Send"]
    XCTAssertTrue(button.waitForExistence(timeout: 5), "the button says Send")
    button.tap()
    let cleared = NSPredicate(format: "value == nil OR value == ''")
    if XCTWaiter.wait(for: [expectation(for: cleared, evaluatedWith: input)], timeout: 3) != .completed, button.exists {
      button.tap()
    }
  }

  private func text(containing needle: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", needle))
  }

  func testBtwWhileAReplyRunsIsAnsweredBesideIt() {
    app.launchArguments.append("--live-turns")
    app.launchEnvironment["TALARIA_LIVE_TURNS_DELAY"] = "2"
    app.launchEnvironment["TALARIA_LIVE_TURNS_PACE_MS"] = "150"
    startTyping()
    XCTAssertTrue(text(containing: "Live question 1").firstMatch.waitForExistence(timeout: 20), "a reply is running")
    XCTAssertTrue(text(containing: "check how the transcript").firstMatch.waitForExistence(timeout: 20), "it is streaming")

    type("/btw what file were you editing?")
    send()
    XCTAssertTrue(notices.firstMatch.waitForExistence(timeout: 5), "the notice shows at once")
    XCTAssertTrue(notices.firstMatch.label.contains("Asking on the side"))
    XCTAssertTrue(notices.firstMatch.label.contains("what file were you editing?"))
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label CONTAINS '/btw'")).count, 0,
      "the question is not a message to the reply")
    XCTAssertEqual(text(containing: "/btw what file").count, 0, "nor queued behind it")
    shoot("btw-notice-while-streaming")

    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "the answer lands as its own card")
    XCTAssertTrue(cards.firstMatch.staticTexts["transcript.side.prompt"].label.contains("what file were you editing?"))
    XCTAssertTrue(text(containing: "Greeting.swift").firstMatch.exists, "the answer renders")
    sleep(1)
    XCTAssertEqual(cards.count, 1, "the second delivery of the same task adds nothing")
    shoot("btw-card-while-streaming")

    // The reply was not stopped or steered: it keeps streaming into one message after the card.
    XCTAssertTrue(text(containing: "Paragraph 3 of the answer").firstMatch.waitForExistence(timeout: 60), "the reply goes on")
    XCTAssertEqual(text(containing: "Paragraph 1 of the answer").count, 1, "the reply is not split in two")
    XCTAssertTrue(cards.firstMatch.exists, "the card stays")
    let newest = text(containing: "Paragraph 3 of the answer").firstMatch
    XCTAssertGreaterThan(cards.firstMatch.frame.minY, newest.frame.minY, "the running reply grows above the card")
    shoot("btw-reply-went-on")
  }

  func testBackgroundTaskReportsBackAndAFailureSaysSo() {
    startTyping()
    type("/bg tidy the notes")
    send()
    XCTAssertTrue(notices.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(notices.firstMatch.label.contains("Running in the background"))
    XCTAssertTrue(notices.firstMatch.label.contains("tidy the notes"))
    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "the result lands as a card")
    XCTAssertTrue(cards.firstMatch.staticTexts["transcript.side.prompt"].label.contains("tidy the notes"), "headed with the task")
    XCTAssertTrue(text(containing: "Tidied").firstMatch.exists)
    shoot("bg-card")

    type("/background fail on purpose")
    send()
    XCTAssertTrue(failedCards.firstMatch.waitForExistence(timeout: 10), "a failure is a failed card")
    XCTAssertTrue(text(containing: "Background task failed").firstMatch.exists)
    XCTAssertTrue(text(containing: "rate limited").firstMatch.exists, "in plain words")
    XCTAssertEqual(text(containing: "error:").count, 0, "without the raw error prefix")
    XCTAssertEqual(cards.count, 1)
    shoot("bg-failed-card")

    cards.firstMatch.press(forDuration: 1.0)
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "long-press offers Copy")
    shoot("bg-card-copy")
  }

  func testTheMenuOffersThemAndEmptyOnesShowUsage() {
    startTyping()
    type("/b")
    let row = { (name: String) in
      self.app.buttons.matching(NSPredicate(format: "identifier == 'slash.row' AND label BEGINSWITH %@", "\(name),")).firstMatch
    }
    XCTAssertTrue(row("/btw").waitForExistence(timeout: 5), "/btw is on the menu")
    XCTAssertTrue(row("/background").exists)
    row("/btw").tap()
    XCTAssertEqual(input.value as? String, "/btw ")
    send()
    XCTAssertTrue(text(containing: "without interrupting it").firstMatch.waitForExistence(timeout: 5), "usage, nothing sent")
    XCTAssertFalse(notices.firstMatch.exists)

    type("/bg")
    send()
    XCTAssertTrue(text(containing: "the result appears here when done").firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(notices.firstMatch.exists)
    XCTAssertFalse(cards.firstMatch.exists)
    shoot("side-usage")
  }
}
