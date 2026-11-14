import XCTest

/// Offline checks of slash commands in the production chat, transcript and composer: the `/`
/// menu, picking from it, and what a sent command shows. `--slash-preview` answers with canned
/// skills and commands instead of the Mac, so no sign-in or gateway is needed.
@MainActor
final class SlashCommandTests: XCTestCase {
  private var app: XCUIApplication!
  private var input: XCUIElement { app.textViews["composer.input"].firstMatch }
  private var menu: XCUIElement { app.descendants(matching: .any)["slash.menu"].firstMatch }
  private var rows: XCUIElementQuery { app.buttons.matching(identifier: "slash.row") }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--short-chat", "--slash-preview"]
    // `TEST_RUNNER_TALARIA_UITEST_APPEARANCE=light` for screenshots in the light look.
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

  private func row(_ name: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == 'slash.row' AND label BEGINSWITH %@", "\(name),")).firstMatch
  }

  private func send() {
    let button = app.buttons["Send"]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
  }

  func testTypingSlashOpensTheMenuAndPickingFillsTheComposer() {
    startTyping()
    XCTAssertFalse(menu.exists, "no menu before a slash")
    input.typeText("/")
    XCTAssertTrue(menu.waitForExistence(timeout: 5), "typing / opens the menu")
    XCTAssertTrue(row("/work").exists)
    XCTAssertTrue(row("/usage").exists)
    XCTAssertFalse(row("/skin").exists, "commands the desktop owns stay off the phone's menu")

    input.typeText("wo")
    XCTAssertTrue(row("/workdash").waitForExistence(timeout: 5))
    let narrowed = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
    wait(for: [narrowed], timeout: 5)
    XCTAssertTrue(row("/work").label.contains("skill"), "a skill is tagged as one")
    shoot("slash-menu-filtered")

    row("/work").tap()
    XCTAssertEqual(input.value as? String, "/work ", "the row replaces the / token with its name and a space")
    XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up")
    let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: menu)
    wait(for: [hidden], timeout: 5)
  }

  func testDeletingTheSlashHidesTheMenu() {
    startTyping()
    input.typeText("/us")
    XCTAssertTrue(row("/usage").waitForExistence(timeout: 5))
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
    // A busy simulator can drop a key press: delete whatever is left, so the `/` is really gone.
    for _ in 0..<3 {
      let left = (input.value as? String ?? "").count
      if left == 0 { break }
      input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left))
    }
    XCTAssertEqual(input.value as? String ?? "", "")
    let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: menu)
    wait(for: [hidden], timeout: 5)
  }

  func testASkillShowsWhatWasTyped() {
    startTyping()
    input.typeText("/work fix the leak")
    XCTAssertFalse(menu.exists, "the menu hides after a space")
    send()
    let bubble = app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label == %@", "/work fix the leak"))
    XCTAssertTrue(bubble.firstMatch.waitForExistence(timeout: 5), "the bubble shows the invocation")
    let body = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The full skill content'"))
    XCTAssertEqual(body.count, 0, "the expanded skill never shows")
    XCTAssertEqual(input.value as? String ?? "", "", "the composer is cleared")
    shoot("slash-skill-bubble")
  }

  func testPlainOutputIsANoticeAndMacOnlyCommandsSaySo() {
    startTyping()
    input.typeText("/usage")
    send()
    let notice = app.descendants(matching: .any).matching(identifier: "transcript.notice").firstMatch
    XCTAssertTrue(notice.waitForExistence(timeout: 5), "plain output shows as a notice")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12,480 tokens'")).firstMatch.exists)
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label == '/usage'")).count, 0,
      "a plain command is not a message to the model")
    shoot("slash-output-notice")

    input.tap()
    input.typeText("/skin dark")
    send()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label == 'Run /skin on the Mac for now.'")).firstMatch.waitForExistence(timeout: 5))
    shoot("slash-mac-only-notice")
  }
}
