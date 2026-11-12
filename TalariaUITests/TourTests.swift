import XCTest

/// Walks every area against a real backend and saves a screenshot of each, for looking at a
/// layout change on iPhone and iPad. Read-only: it opens screens and makes no model calls.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:4300 \
///   TEST_RUNNER_TALARIA_UITEST_TOUR=1 TEST_RUNNER_TALARIA_UITEST_SHOTS=/some/dir \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/TourTests
@MainActor
final class TourTests: XCTestCase {
  private var app: XCUIApplication!
  private var shots: String?
  private var prefix = ""

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty, environment["TALARIA_UITEST_TOUR"] != nil else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_TOUR to take the tour.")
    }
    shots = environment["TALARIA_UITEST_SHOTS"]
    prefix = environment["TALARIA_UITEST_PREFIX"] ?? (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
    continueAfterFailure = true
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(prefix)-\(name).png"))
    }
  }

  /// An area: the iPad sidebar row, an iPhone tab, or on iPhone the inbox's More menu, which
  /// holds Kanban and Settings.
  private func open(tab title: String) {
    let area = app.buttons["area.\(title.lowercased())"]
    if area.waitForExistence(timeout: 2) && area.isHittable {
      area.tap()
      return
    }
    let tab = app.tabBars.buttons[title]
    if tab.exists && tab.isHittable {
      tab.tap()
      return
    }
    app.tabBars.buttons["Chats"].tap()
    let more = app.buttons["home.more"]
    for _ in 0..<4 where !more.exists {
      let back = app.buttons["BackButton"].firstMatch
      guard back.exists else { break }
      back.tap()
    }
    guard more.waitForExistence(timeout: 3) else {
      XCTFail("no way to reach \(title)")
      return
    }
    more.tap()
    let item = app.buttons[title].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 3), "\(title) is not in the More menu")
    item.tap()
  }

  /// The iPhone tab bar holds only the areas used most.
  private func checkPhoneTabs() {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
    let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
    XCTAssertEqual(names, ["Chats", "Bots", "Cron"], "tab bar: \(names)")
  }

  /// The first such row that is not working: opening a chat that another client is running can
  /// take it over, and the tour is meant to change nothing.
  private func tapFirst(_ identifier: String, timeout: TimeInterval = 20) -> Bool {
    let element = app.buttons.matching(
      NSPredicate(format: "identifier == %@ AND NOT (label CONTAINS 'Working')", identifier)).firstMatch
    guard element.waitForExistence(timeout: timeout) else { return false }
    element.tap()
    return true
  }

  func testTour() throws {
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "home did not load")
    checkPhoneTabs()
    sleep(3)
    shoot("01-chats")
    app.swipeUp()
    sleep(1)
    shoot("01b-chats-scrolled")
    app.swipeDown()
    if tapFirst("agent.more", timeout: 5) {
      sleep(3)
      shoot("01c-agent")
      // The system back button; on iPad the first bar button is the sidebar toggle.
      let back = app.buttons["BackButton"].firstMatch
      if back.waitForExistence(timeout: 3) { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
      sleep(1)
    }

    if tapFirst("session.row") {
      sleep(4)
      shoot("02-chat")
      let files = app.buttons.matching(identifier: "transcript.file").firstMatch
      if files.waitForExistence(timeout: 3) {
        files.tap()
        sleep(3)
        shoot("02b-file")
        app.buttons["Done"].firstMatch.tap()
      }
      if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    open(tab: "Bots")
    sleep(2)
    shoot("03-bots")
    if tapFirst("bot.row") {
      sleep(3)
      shoot("04-bot")
      if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    open(tab: "Kanban")
    sleep(3)
    shoot("05-kanban")
    if tapFirst("kanban.card") {
      sleep(3)
      shoot("06-card")
      if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    open(tab: "Cron")
    sleep(3)
    shoot("07-cron")
    if tapFirst("cron.row") {
      sleep(3)
      shoot("08-job")
      if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    open(tab: "Settings")
    sleep(1)
    shoot("09-settings")

    if UIDevice.current.userInterfaceIdiom == .pad {
      XCUIDevice.shared.orientation = .landscapeLeft
      sleep(2)
      open(tab: "Chats")
      sleep(2)
      shoot("10-landscape-chats")
      if tapFirst("session.row") {
        sleep(4)
        shoot("11-landscape-chat")
      }
      open(tab: "Kanban")
      sleep(2)
      shoot("12-landscape-kanban")
      XCUIDevice.shared.orientation = .portrait
    }
  }
}
