import XCTest

/// Prototype: the inbox's origin filter. Read-only against a real backend; opens no chats.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file> TEST_RUNNER_TALARIA_UITEST_ORIGINS=1 \
///   TEST_RUNNER_TALARIA_UITEST_SHOTS=/some/dir \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/OriginFilterTests
@MainActor
final class OriginFilterTests: XCTestCase {
  private var app: XCUIApplication!
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty,
          environment["TALARIA_UITEST_ORIGINS"] != nil else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_ORIGINS.")
    }
    shots = environment["TALARIA_UITEST_SHOTS"]
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("origins-\(name).png"))
    }
  }

  private func pick(_ prefix: String) {
    let filter = app.buttons["home.originFilter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 20))
    filter.tap()
    let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(prefix)")
    shoot("menu-\(prefix.lowercased().replacingOccurrences(of: " ", with: "-"))")
    item.tap()
  }

  func testFilterMenu() {
    XCTAssertTrue(app.buttons["session.row"].firstMatch.waitForExistence(timeout: 30))
    sleep(3)  // the origins file loads after the first list
    pick("All chats")
    shoot("all")
    pick("Talaria")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Showing Talaria'")).firstMatch
      .waitForExistence(timeout: 5))
    shoot("talaria")
    pick("Automation")
    shoot("automation")
    app.buttons["Show all chats"].tap()
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Showing'")).firstMatch
      .waitForExistence(timeout: 2))
    shoot("cleared")
  }
}
