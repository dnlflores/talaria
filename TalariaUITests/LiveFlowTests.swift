import XCTest

/// End-to-end checks against a real Hermes backend. They are skipped unless a gate is named:
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:4300 \
///   TEST_RUNNER_TALARIA_UITEST_BOT=Scout \
///   xcodebuild test -project Talaria.xcodeproj -scheme Talaria -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// Each run costs a few model calls on the chosen bot and archives the chat it creates.
/// `TEST_RUNNER_TALARIA_UITEST_SHOTS=/some/dir` also saves screenshots there.
@MainActor
final class LiveFlowTests: XCTestCase {
  private var app: XCUIApplication!
  private var server = ""
  private var bot = "Hermes"
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER to run the live flow.")
    }
    self.server = server
    bot = environment["TALARIA_UITEST_BOT"] ?? "Hermes"
    shots = environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = server
    app.launch()
  }

  private func shoot(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let shots {
      try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(name).png"))
    }
  }

  private func send(_ text: String) {
    let input = app.textViews["composer.input"].firstMatch.exists ? app.textViews["composer.input"].firstMatch : app.textFields["composer.input"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 20), "composer input")
    input.tap()
    input.typeText(text)
    let sendButton = app.buttons["Send"]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
    sendButton.tap()
  }

  /// Waits for assistant text containing `needle` that is not part of the user's own message.
  private func waitForAnswer(containing needle: String, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "identifier == 'transcript.answer' AND label CONTAINS[c] %@", needle)
    return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
  }

  func testNewChatStreamsToolsQuestionsAndArchives() throws {
    // Home lists conversations from the backend.
    let compose = app.buttons["New chat"]
    XCTAssertTrue(compose.waitForExistence(timeout: 30), "home did not load")
    XCTAssertTrue(app.staticTexts["Talaria"].exists || app.otherElements["Talaria"].exists)
    shoot("01-home")

    // New chat with the chosen bot.
    compose.tap()
    let botRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", bot)).firstMatch
    if botRow.waitForExistence(timeout: 10) {
      shoot("02-bot-picker")
      botRow.tap()
    }

    // 1. A plain turn streams an answer.
    let marker = "talaria-\(Int(Date().timeIntervalSince1970) % 100_000)"
    send("UI test \(marker). What is 17 times 3? Reply with just the number.")
    XCTAssertTrue(waitForAnswer(containing: "51", timeout: 120), "no streamed answer")
    XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 30), "turn did not finish")
    shoot("03-answer")

    // 2. A turn that uses a tool shows its work, collapsed once it finishes.
    send("Run this in the terminal and tell me exactly what it printed: echo wing-$((40+2))")
    XCTAssertTrue(waitForAnswer(containing: "wing-42", timeout: 180), "no answer after the tool call")
    let workRows = app.buttons.matching(NSPredicate(format: "identifier == 'transcript.work' AND label BEGINSWITH 'Worked'"))
    XCTAssertTrue(workRows.firstMatch.waitForExistence(timeout: 30), "no work log row")
    shoot("04-tool-turn")
    workRows.element(boundBy: workRows.count - 1).tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch.waitForExistence(timeout: 5), "tool row missing")
    shoot("05-work-log-open")

    // 3. A question from the agent is answered in place.
    send("Use the clarify tool to ask me one question: 'Which color?' with exactly two choices, Crimson and Teal. Then reply with only the color I picked.")
    let teal = app.buttons.matching(NSPredicate(format: "label == 'Teal'")).firstMatch
    XCTAssertTrue(teal.waitForExistence(timeout: 180), "the question never arrived")
    shoot("06-question")
    teal.tap()
    XCTAssertTrue(waitForAnswer(containing: "Teal", timeout: 120), "no answer after choosing")
    XCTAssertTrue(app.staticTexts["Answered"].waitForExistence(timeout: 10))
    shoot("07-question-answered")

    // 4. The model sheet loads the catalog for this chat.
    app.buttons["Model and effort"].tap()
    XCTAssertTrue(app.staticTexts["THINKING EFFORT"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'model.row'")).firstMatch.waitForExistence(timeout: 60), "model catalog did not load")
    shoot("08-models")
    app.buttons["Done"].tap()

    // 5. Renaming reaches the backend: back home the chat is listed under its new name, and archiving removes it.
    app.buttons["More"].firstMatch.tap()
    app.buttons["Rename"].firstMatch.tap()
    let titleField = app.alerts.textFields["Title"]
    XCTAssertTrue(titleField.waitForExistence(timeout: 5), "rename alert")
    let existing = (titleField.value as? String) ?? ""
    titleField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + marker)
    app.alerts.buttons["Rename"].tap()

    app.navigationBars.buttons.element(boundBy: 0).tap()
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'session.row' AND label CONTAINS %@", marker)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the renamed chat is not in the list")
    shoot("09-home-after")
    row.swipeLeft()
    let archive = app.buttons["Archive"]
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    archive.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 20), "archive did not remove the chat")
  }
}
