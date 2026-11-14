import XCTest

/// The app icon's quick actions, from the home screen. No Mac needed: `--seed-recents` puts
/// made-up chats on the icon, the app points at an address nothing answers, and the screen names
/// the chat a tap asked for and that it waits for sign-in (`debug.openTrace`). With a Mac, the
/// same taps open that chat once the app is ready (`PushCenter.openPending`).
///
/// `TEST_RUNNER_TALARIA_UITEST_SHOTS=<dir>` saves the icon's menu and each result.
@MainActor
final class QuickActionTests: XCTestCase {
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  private var shots: String?

  override func setUp() async throws {
    shots = ProcessInfo.processInfo.environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = false
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

  private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

  /// Launches with the seeded chats and nothing to sign in to.
  private func launchSeeded(_ extra: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--seed-recents"]
    app.launchEnvironment["TALARIA_SERVER"] = "http://127.0.0.1:9"
    for (key, value) in extra { app.launchEnvironment[key] = value }
    app.launch()
    XCTAssertTrue(trace(app).waitForExistence(timeout: 15), "the app did not come up")
    // The address field takes the keyboard, which would cover the icon's menu after leaving.
    app.scrollViews.firstMatch.swipeDown()
    return app
  }

  private func trace(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts["debug.openTrace"]
  }

  /// Presses the Talaria icon on the home screen until its menu shows `item`, then taps it.
  private func tapQuickAction(_ item: String, shot: String? = nil, alsoShows others: [String] = []) {
    XCUIDevice.shared.press(.home)
    let icons = springboard.icons.matching(identifier: "Talaria")
    XCTAssertTrue(icons.firstMatch.waitForExistence(timeout: 10), "no Talaria icon on the home screen")
    // A fresh simulator puts new apps on a later page. The iPad dock can show the icon again,
    // below the home screen's.
    func onScreen() -> XCUIElement? {
      icons.allElementsBoundByIndex.filter(\.isHittable).min { $0.frame.minY < $1.frame.minY }
    }
    var found = onScreen()
    for _ in 0..<4 where found == nil {
      springboard.swipeLeft()
      sleep(1)
      found = onScreen()
    }
    guard let icon = found else { return XCTFail("the Talaria icon is not on screen") }
    let entry = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
    for _ in 0..<3 where !entry.exists {
      icon.press(forDuration: 1.5)
      _ = entry.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(entry.exists, "the icon's menu has no \(item)")
    for other in others {
      let line = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", other)).firstMatch
      XCTAssertTrue(line.exists, "the icon's menu has no \(other)")
    }
    if let shot { shoot(shot) }
    entry.tap()
  }

  private func expectTrace(_ app: XCUIApplication, _ expected: String, step: String) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app did not open (\(step))")
    let label = trace(app)
    XCTAssertTrue(label.waitForExistence(timeout: 15), "no trace (\(step))")
    let predicate = NSPredicate(format: "label == %@", expected)
    let matched = XCTNSPredicateExpectation(predicate: predicate, object: label)
    XCTAssertEqual(XCTWaiter().wait(for: [matched], timeout: 10), .completed, "\(step): \(label.label)")
    shoot("\(device)-\(step)")
  }

  func testMenuShowsNewChatAndTheRecentChats() throws {
    _ = launchSeeded()
    tapQuickAction(
      "New chat", shot: "\(device)-menu",
      alsoShows: ["Fix the flaky checkout test", "Plan the team offsite", "Untitled chat"])
    let app = XCUIApplication()
    expectTrace(app, "new chat ada (waiting for sign-in)", step: "menu-new-chat")
    // The untitled chat shows by its stand-in name, and opens too.
    tapQuickAction("Untitled chat")
    expectTrace(app, "chat default/seed-3 (waiting for sign-in)", step: "menu-untitled")
  }

  func testARecentChatOpensWhileTheAppIsInTheBackground() throws {
    let app = launchSeeded()
    tapQuickAction("Plan the team offsite")
    expectTrace(app, "chat ada/seed-2 (waiting for sign-in)", step: "warm-recent")
  }

  func testARecentChatOpensTheAppAfterItWasClosed() throws {
    let app = launchSeeded()
    app.terminate()
    tapQuickAction("Fix the flaky checkout test")
    expectTrace(app, "chat default/seed-1 (waiting for sign-in)", step: "cold-recent")
  }

  func testNewChatStartsWithTheBotUsedLast() throws {
    let app = launchSeeded()
    app.terminate()
    tapQuickAction("New chat")
    expectTrace(app, "new chat ada (waiting for sign-in)", step: "cold-new-chat")
  }

  /// The scene delegate must not take over what already opened chats: a Live Activity's link and
  /// a tapped notification.
  func testLinksAndNotificationsStillOpenTheirChat() throws {
    let app = launchSeeded()
    XCUIDevice.shared.press(.home)
    XCUIDevice.shared.system.open(URL(string: "talaria://chat?profile=ada&session=seed-link")!)
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 3) { open.tap() }
    expectTrace(app, "chat ada/seed-link (waiting for sign-in)", step: "link")

    app.terminate()
    let marker = "quick-note-\(Int(Date().timeIntervalSince1970) % 100_000)"
    let noted = launchSeeded([
      "TALARIA_PUSH_PROMPT": "1", "TALARIA_TEST_NOTIFICATION": "default/seed-note/\(marker)",
      "TALARIA_TEST_NOTIFICATION_DELAY": "15",
    ])
    // The notification shows 15 s after it is allowed: leave the app well before that.
    let allow = springboard.buttons["Allow"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
    XCUIDevice.shared.press(.home)
    shoot("\(device)-notification-waiting")
    let banner = springboard.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
    if !banner.waitForExistence(timeout: 20) {
      shoot("\(device)-notification-missing")
      XCTFail("no notification banner")
    }
    banner.tap()
    expectTrace(noted, "chat default/seed-note (waiting for sign-in)", step: "notification")
  }

  override func tearDown() async throws {
    let app = XCUIApplication()
    app.launchArguments = ["--no-seed-recents"]
    app.launch()
    app.terminate()
  }
}
