import XCTest

/// A chat another Hermes process is running (a terminal running its own agent, outside the
/// gateway) shows as working in the inbox and in the chat, though no events for it reach the
/// app. Read-only: the chat opens in watch mode and nothing is sent. Chats the desktop app runs
/// are not elsewhere: they run in the gateway this app talks to.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file from scripts/sign-in.py> \
///   TEST_RUNNER_TALARIA_UITEST_ELSEWHERE="<title of a chat a terminal is running>" \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/ElsewhereTests
@MainActor
final class ElsewhereTests: XCTestCase {
  private var app: XCUIApplication!
  private var title = ""
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty,
      let title = environment["TALARIA_UITEST_ELSEWHERE"], !title.isEmpty
    else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_ELSEWHERE.")
    }
    self.title = title
    shots = environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = server
    app.launchEnvironment["TALARIA_SIGNIN_FILE"] = environment["TALARIA_UITEST_SIGNIN"] ?? ""
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("elsewhere-\(name).png"))
    }
  }

  func testAChatRunningElsewhereSaysItIsWorking() throws {
    XCTAssertTrue(app.waitForHome(), "home did not load")
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'session.row' AND label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the chat is not in the inbox")
    let saysWorking = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Working'"), object: row)
    XCTAssertEqual(XCTWaiter().wait(for: [saysWorking], timeout: 25), .completed, "the inbox row does not say Working: \(row.label)")
    shoot("1-inbox")

    row.tap()
    let working = app.descendants(matching: .any).matching(identifier: "transcript.working").firstMatch
    XCTAssertTrue(working.waitForExistence(timeout: 30), "the open chat shows no working row")
    shoot("2-chat")
    // Watching, not driving: the stop button belongs to whoever runs the turn.
    XCTAssertFalse(app.buttons["Stop"].exists, "a chat run elsewhere offered Stop")
  }
}
