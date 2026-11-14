import XCTest

/// Walks every area against a real backend and saves a screenshot of each, for looking at a
/// layout change on iPhone and iPad. Read-only: it opens screens and makes no model calls.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file from scripts/sign-in.py> \
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(prefix)-\(name).png"))
    }
  }

  /// An area: the side dock (iPad, an unfolded iPhone Duo), the iPhone dock (Chats, Agents,
  /// Settings), or on iPhone the inbox's More menu, which holds Kanban and Cron.
  private func open(tab title: String) {
    let area = app.buttons["area.\(title.lowercased())"]
    if area.waitForExistence(timeout: 2) && area.isHittable {
      area.tap()
      return
    }
    // The dock shows on an area's first screen only: step back to it.
    let dockChats = app.buttons["dock.chats"]
    if UIDevice.current.userInterfaceIdiom == .phone {
      for _ in 0..<5 where !dockChats.exists {
        guard goBack() else { break }
        sleep(1)
      }
    }
    let dock = app.buttons["dock.\(title.lowercased())"]
    if dock.exists && dock.isHittable {
      dock.tap()
      return
    }
    let chats = app.buttons["area.chats"]
    if chats.exists { chats.tap() } else { dockChats.tap() }
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

  /// The back button of the page on top. On iPad the first bar button is the sidebar toggle, so
  /// only the system back button (`BackButton`) will do.
  @discardableResult
  private func goBack() -> Bool {
    // A sheet that just closed can hide it for a moment. On a folded iPhone Duo the bar's
    // buttons sit in a column beside the screen and are not under `navigationBars`.
    let back = app.buttons["BackButton"].firstMatch
    if back.waitForExistence(timeout: 3) {
      back.tap()
      return true
    }
    guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
    let first = app.navigationBars.buttons.element(boundBy: 0)
    guard first.exists else { return false }
    first.tap()
    return true
  }

  /// The iPhone dock holds Chats and Agents, then New chat and Settings; the side dock (iPad, an
  /// unfolded iPhone Duo) has Chats, Agents, Kanban, New chat and Settings. Cron is in the More
  /// menu on both.
  private func checkDock() {
    if app.buttons["area.chats"].waitForExistence(timeout: 5) {
      for id in ["area.chats", "area.agents", "area.kanban", "area.new", "area.settings"] {
        XCTAssertTrue(app.buttons[id].exists, "\(id) is not in the side dock")
      }
      XCTAssertFalse(app.buttons["area.cron"].exists, "Cron is in the side dock")
      XCTAssertFalse(app.buttons["dock.chats"].exists, "the bottom dock shows beside the side dock")
    } else if UIDevice.current.userInterfaceIdiom == .phone {
      for id in ["dock.chats", "dock.agents", "dock.new", "dock.settings"] {
        XCTAssertTrue(app.buttons[id].exists, "\(id) is not in the dock")
      }
      let systemTab = app.tabBars.buttons.firstMatch
      XCTAssertFalse(systemTab.exists && systemTab.isHittable, "the system tab bar shows")
    } else {
      XCTFail("no dock on iPad")
    }
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
    checkDock()
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
      // The model chooser opens from the composer: the model in use and favourites, then every
      // model. Nothing is switched. Not there in a chat that cannot reply here (a terminal holds it).
      let modelButton = app.buttons["composer.model"]
      if modelButton.waitForExistence(timeout: 3), modelButton.isEnabled {
        modelButton.tap()
        if app.descendants(matching: .any)["model.current"].waitForExistence(timeout: 20) {
          sleep(2)
          shoot("02c-model")
          app.buttons["model.all"].tap()
          if app.buttons.matching(identifier: "model.provider").firstMatch.waitForExistence(timeout: 60) {
            sleep(2)
            shoot("02d-model-list")
          }
        }
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
      }
      if UIDevice.current.userInterfaceIdiom != .pad { goBack() }
    }

    open(tab: "Agents")
    sleep(2)
    if UIDevice.current.userInterfaceIdiom == .pad, tapFirst("bot.row") { sleep(2) }
    shoot("03-agents")
    // The hub's pages: the default model (and every model), the skills. Nothing is changed.
    let modelRow = app.buttons["hub.model"]
    if modelRow.waitForExistence(timeout: 5) {
      modelRow.tap()
      sleep(4)
      shoot("04-default-model")
      let all = app.buttons["model.all"]
      if all.waitForExistence(timeout: 5) {
        all.tap()
        sleep(3)
        shoot("04b-all-models")
        goBack()
        sleep(1)
      }
      goBack()
      sleep(1)
    }
    let skillsRow = app.buttons["hub.skills"]
    if skillsRow.waitForExistence(timeout: 5) {
      skillsRow.tap()
      sleep(3)
      shoot("04c-skills")
      goBack()
      sleep(1)
    }
    app.swipeUp()
    sleep(1)
    shoot("04d-agents-scrolled")
    // Memory & Learning: the constellation of memories, then one in full (AgentHubTests picks a star).
    let memoryRow = app.buttons["hub.memory"]
    if memoryRow.waitForExistence(timeout: 5) {
      memoryRow.tap()
      if app.descendants(matching: .any)["constellation.header"].waitForExistence(timeout: 30) {
        sleep(2)
        shoot("04e-memory")
        app.swipeUp()
        sleep(1)
        shoot("04g-memory-list")
        let memory = app.buttons.matching(identifier: "learning.note").firstMatch
        if memory.waitForExistence(timeout: 3), memory.isHittable {
          memory.tap()
          sleep(3)
          shoot("04h-memory")
          goBack()
          sleep(1)
        }
      }
      goBack()
      sleep(1)
    }
    app.swipeDown()

    open(tab: "Kanban")
    sleep(3)
    shoot("05-kanban")
    if tapFirst("kanban.card") {
      sleep(3)
      shoot("06-card")
      if UIDevice.current.userInterfaceIdiom != .pad { goBack() }
    }

    open(tab: "Cron")
    sleep(3)
    shoot("07-cron")
    if tapFirst("cron.row") {
      sleep(3)
      shoot("08-job")
      if UIDevice.current.userInterfaceIdiom != .pad { goBack() }
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
