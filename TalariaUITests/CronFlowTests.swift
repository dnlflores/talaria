import XCTest

/// Pauses and resumes a cron job from the app, against a real backend. It needs a throwaway job
/// that is safe to resume (a far-off schedule), created before and deleted after the run:
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file from scripts/sign-in.py> \
///   TEST_RUNNER_TALARIA_UITEST_CRON_JOB="Talaria test job" \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/CronFlowTests
///
/// It never runs the job.
@MainActor
final class CronFlowTests: XCTestCase {
  private var app: XCUIApplication!
  private var jobName = ""
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty,
      let job = environment["TALARIA_UITEST_CRON_JOB"], !job.isEmpty
    else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_CRON_JOB to run the cron flow.")
    }
    jobName = job
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("cron-\(name).png"))
    }
  }

  func testPauseAndResume() throws {
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "home did not load")
    // Cron is not in the dock: it opens from the inbox's More menu.
    app.buttons["home.more"].tap()
    let cron = app.buttons["Cron"].firstMatch
    XCTAssertTrue(cron.waitForExistence(timeout: 5), "Cron is not in the More menu")
    cron.tap()

    let row = app.buttons.matching(NSPredicate(format: "identifier == 'cron.row' AND label CONTAINS %@", jobName)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the test job is not listed")
    XCTAssertTrue(row.label.contains("Paused"), "the test job should start paused, got: \(row.label)")
    row.tap()

    let toggle = app.buttons["cron.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    XCTAssertTrue(toggle.label.contains("Resume"), "expected a Resume button, got \(toggle.label)")
    shoot("1-paused")
    toggle.tap()
    let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Pause'"), object: toggle)
    XCTAssertEqual(XCTWaiter().wait(for: [resumed], timeout: 20), .completed, "resume did not take")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'in '")).firstMatch.waitForExistence(timeout: 10),
                  "no next run shown after resuming")
    shoot("2-resumed")

    toggle.tap()
    let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Resume'"), object: toggle)
    XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 20), .completed, "pause did not take")
    shoot("3-paused-again")
  }
}
