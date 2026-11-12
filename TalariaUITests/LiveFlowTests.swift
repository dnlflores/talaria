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

  private var workingRow: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "transcript.working").firstMatch
  }

  /// Answers on screen. A running turn shows none: its text stays with its steps until it ends.
  private var answers: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "transcript.answer")
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

    // 1. A plain turn streams an answer, and says it is working until the answer is in.
    let marker = "talaria-\(Int(Date().timeIntervalSince1970) % 100_000)"
    send("UI test \(marker). What is 17 times 3? Reply with just the number.")
    XCTAssertTrue(workingRow.waitForExistence(timeout: 10), "no working row after sending")
    XCTAssertTrue(waitForAnswer(containing: "51", timeout: 120), "no streamed answer")
    XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 30), "turn did not finish")
    XCTAssertTrue(workingRow.waitForNonExistence(timeout: 15), "the working row outlived the turn")
    shoot("03-answer")

    // 2. A turn that uses a tool shows what it is running, then its work, collapsed once it finishes.
    let answersBefore = answers.count
    send("Say one short sentence about what you are about to do, then run this in the terminal and tell me exactly what it printed: sleep 6; echo wing-$((40+2))")
    let running = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'transcript.working' AND label CONTAINS 'Running a command'")).firstMatch
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the working row never named the running command")
    XCTAssertEqual(answers.count, answersBefore, "a running turn showed its note as an answer")
    shoot("04a-running")
    XCTAssertTrue(waitForAnswer(containing: "wing-42", timeout: 180), "no answer after the tool call")
    let workRows = app.buttons.matching(NSPredicate(format: "identifier == 'transcript.work' AND label BEGINSWITH 'Worked'"))
    XCTAssertTrue(workRows.firstMatch.waitForExistence(timeout: 30), "no work log row")
    shoot("04-tool-turn")
    workRows.element(boundBy: workRows.count - 1).tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch.waitForExistence(timeout: 5), "tool row missing")
    shoot("05-work-log-open")

    // 2a. Leaving a chat while its reply runs and coming back still shows it working, and the
    // inbox says so in between.
    let answersBeforeHeron = answers.count
    send("Say one short sentence about what you are about to do, then run this in the terminal and tell me exactly what it printed: sleep 20; echo heron-$((5+2))")
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the second command never showed as running")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    // The inbox groups chats by bot; the bot's lead row is its newest chat, this one.
    let newest = app.buttons.matching(NSPredicate(format: "identifier == 'session.row' AND label BEGINSWITH %@", bot)).firstMatch
    XCTAssertTrue(newest.waitForExistence(timeout: 20))
    let saysWorking = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Working'"), object: newest)
    XCTAssertEqual(XCTWaiter().wait(for: [saysWorking], timeout: 20), .completed, "the inbox did not say the chat is working")
    shoot("04c-inbox-working")
    newest.tap()
    XCTAssertTrue(workingRow.waitForExistence(timeout: 30), "reopening a running chat did not show it working")
    let asked = app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label CONTAINS 'heron'"))
    XCTAssertEqual(asked.count, 1, "reopening a running chat repeated the message that started it")
    // The note the turn wrote before its command is a step, not an answer, after reopening too,
    // and the command it is running shows by name.
    XCTAssertEqual(answers.count, answersBeforeHeron, "reopening a running chat showed its note as an answer")
    XCTAssertTrue(running.waitForExistence(timeout: 10), "reopening a running chat did not name the running command")
    shoot("04d-reopened-working")
    XCTAssertTrue(waitForAnswer(containing: "heron-7", timeout: 180), "no answer after coming back")
    XCTAssertTrue(workingRow.waitForNonExistence(timeout: 20), "the working row outlived the reopened turn")

    // 2b. A file the turn writes is listed under its answer and opens on the phone.
    let fileName = "talaria-uitest-\(marker).txt"
    send("Use the write_file tool to create /tmp/\(fileName) containing exactly the word feather. Then reply with its absolute path.")
    let chip = app.buttons.matching(NSPredicate(format: "identifier == 'transcript.file' AND label CONTAINS %@", fileName)).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 180), "the written file was not listed under the answer")
    let chips = app.buttons.matching(NSPredicate(format: "identifier == 'transcript.file' AND label CONTAINS %@", fileName))
    XCTAssertEqual(chips.count, 1, "the written file is listed more than once")
    shoot("05a-file-chip")
    chip.tap()
    XCTAssertTrue(app.staticTexts["feather"].waitForExistence(timeout: 30), "the file did not open with its contents")
    XCTAssertTrue(app.buttons["file.share"].exists, "no share button for the file")
    shoot("05b-file-open")
    app.buttons["Done"].firstMatch.tap()

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
