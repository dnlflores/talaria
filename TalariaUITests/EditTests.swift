import XCTest

/// Offline checks of Edit in the production chat, transcript and composer: long-press the newest
/// message > Edit, change the words and send them, or Cancel. `--scroll-preview` stands in for the
/// Mac: the edit takes the preview's newest turn off, shows the new words and streams a canned
/// reply, so no sign-in or gateway is needed.
@MainActor
final class EditTests: XCTestCase {
  private var app: XCUIApplication!
  private var input: XCUIElement { app.textViews["composer.input"].firstMatch }
  private var bar: XCUIElement { app.descendants(matching: .any)["composer.editing"].firstMatch }
  private let question = "Inspect the latest change."
  private let edited = "Inspect only the tests."
  private let draft = "A draft in progress"
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

  private func bubbles(_ words: String) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label == %@", words))
  }

  private func texts(containing words: String) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words))
  }

  private func waitFor(_ predicate: String, _ element: Any, timeout: Double = 10) {
    let done = expectation(for: NSPredicate(format: predicate), evaluatedWith: element)
    wait(for: [done], timeout: timeout)
  }

  private var composerText: String { input.value as? String ?? "" }

  /// Types a draft, long-presses the newest message and picks Edit.
  private func startEditing() {
    let bubble = bubbles(question).firstMatch
    XCTAssertTrue(bubble.waitForExistence(timeout: 15), "the preview's newest message")
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(draft)
    waitFor("value == '\(draft)'", input)

    let edit = app.buttons["Edit"]
    for _ in 0..<3 where !edit.exists {
      bubble.press(forDuration: 1.2)
      _ = edit.waitForExistence(timeout: 3)
    }
    // The menu animates in; a tap before it settles can be lost.
    waitFor("hittable == true", edit, timeout: 3)
    XCTAssertTrue(app.buttons["Try again"].exists, "Edit sits beside Try again")
    XCTAssertTrue(app.buttons["Copy"].exists, "and Copy")
    Thread.sleep(forTimeInterval: 0.5)
    shoot("edit-menu")
    edit.tap()
    waitFor("exists == false", edit, timeout: 5)

    XCTAssertTrue(bar.waitForExistence(timeout: 5), "the editing bar shows")
    XCTAssertTrue(texts(containing: "Editing your message").firstMatch.exists)
    waitFor("value == '\(question)'", input)
  }

  func testEditTheNewestMessageAndSendIt() {
    app.launch()
    startEditing()
    shoot("edit-bar")

    // Replace the words: clear them and type new ones.
    input.tap()
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: question.count + 2))
    input.typeText(edited)
    waitFor("value == '\(edited)'", input)
    shoot("edit-changed")
    XCTAssertTrue(app.buttons["Send"].exists, "the send button sends the edit")
    app.buttons["Send"].tap()

    // The old turn goes, the new words show once, a fresh reply streams in under them.
    waitFor("count == 0", bubbles(question))
    waitFor("count == 0", texts(containing: oldReply))
    waitFor("count == 1", bubbles(edited))
    XCTAssertTrue(texts(containing: "A fresh answer").firstMatch.waitForExistence(timeout: 10), "a new reply arrives")
    // The draft set aside comes back, and the bar is gone.
    waitFor("exists == false", bar, timeout: 5)
    waitFor("value == '\(draft)'", input)
    shoot("edit-sent")
    // Once the reply ends, the new message is the newest and offers Edit again.
    XCTAssertTrue(texts(containing: "a few seconds").firstMatch.waitForExistence(timeout: 20))
    XCTAssertEqual(bubbles(question).count, 0, "the old words are nowhere")
  }

  func testCancelBringsTheDraftBack() {
    app.launch()
    startEditing()
    input.tap()
    input.typeText(" And the docs.")
    app.buttons["composer.editing.cancel"].tap()
    waitFor("exists == false", bar, timeout: 5)
    waitFor("value == '\(draft)'", input)
    XCTAssertEqual(bubbles(question).count, 1, "the message is untouched")
    XCTAssertTrue(texts(containing: oldReply).firstMatch.exists, "and so is its reply")
    shoot("edit-cancelled")
  }

  func testTheReplyOffersNoEdit() {
    app.launch()
    let reply = app.descendants(matching: .any).matching(identifier: "transcript.answer")
      .matching(NSPredicate(format: "label CONTAINS %@", oldReply)).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 15))
    let retry = app.buttons["Try again"]
    for _ in 0..<3 where !retry.exists {
      reply.press(forDuration: 1.2)
      _ = retry.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(retry.exists, "the reply's menu is open")
    XCTAssertFalse(app.buttons["Edit"].exists, "Edit is only on the person's message")
    shoot("edit-reply-menu")
  }
}
