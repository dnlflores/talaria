import XCTest

/// The Live Activity's look, without a Mac: the app starts a demo activity in one phase
/// (`TALARIA_DEMO_ACTIVITY`, DEBUG only), then this goes Home to see the Dynamic Island and pulls
/// down the Lock Screen view. Screenshots only; nothing is asserted about pixels.
///
///   TEST_RUNNER_TALARIA_UITEST_ACTIVITY_LOOK=1 TEST_RUNNER_TALARIA_UITEST_SHOTS=/some/dir \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/ActivityLookTests
@MainActor
final class ActivityLookTests: XCTestCase {
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TALARIA_UITEST_ACTIVITY_LOOK"] != nil else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_ACTIVITY_LOOK to look at the Live Activity.")
    }
    shots = environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = true
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

  func testEveryPhase() throws {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for phase in ["working", "waiting", "done", "failed"] {
      let app = XCUIApplication()
      app.launchEnvironment["TALARIA_DEMO_ACTIVITY"] = phase
      app.launch()
      sleep(3)
      XCUIDevice.shared.press(.home)
      sleep(2)
      shoot("activity-\(phase)-island")
      // Long-press the island for the expanded view.
      let island = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025))
      island.press(forDuration: 1.2)
      sleep(1)
      shoot("activity-\(phase)-expanded")
      XCUIDevice.shared.press(.home)
      sleep(1)
      // The Lock Screen view, as Notification Center shows it.
      let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.002))
      top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
      sleep(2)
      shoot("activity-\(phase)-lockscreen")
      XCUIDevice.shared.press(.home)
      sleep(1)
      app.terminate()
    }
  }
}

/// The composer with the on-screen keyboard after it moved to a text view (so a hardware Return
/// can send, see `ComposerInput`): its Return still adds a line, and a two-line draft sends whole.
/// XCTest cannot stand in for a hardware Return here: on the iOS 27 simulator it delivers
/// `typeKey(.return)` to no responder at all (modifier presses and letters arrive), so that path
/// is covered by `ComposerKeyTests` and checked by hand with a real keyboard. Runs against a real
/// backend like `LiveFlowTests` and starts one reply, which it stops before archiving the chat.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file> TEST_RUNNER_TALARIA_UITEST_BOT=<bot title> \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/ComposerKeyboardTests
@MainActor
final class ComposerKeyboardTests: XCTestCase {
  private var app: XCUIApplication!
  private var bot = "Hermes"
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER to run the composer flow.")
    }
    bot = environment["TALARIA_UITEST_BOT"] ?? "Hermes"
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(name).png"))
    }
  }

  private var input: XCUIElement { app.textViews["composer.input"].firstMatch }

  private func userMessage(containing needle: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label CONTAINS %@", needle)).firstMatch
  }

  func testOnScreenReturnAddsALineAndTheDraftSendsWhole() throws {
    let compose = app.buttons["New chat"]
    XCTAssertTrue(compose.waitForExistence(timeout: 30), "home did not load")
    compose.tap()
    let botRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", bot)).firstMatch
    if botRow.waitForExistence(timeout: 10) { botRow.tap() }

    let marker = "kbd-\(Int(Date().timeIntervalSince1970) % 100_000)"
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the composer is not a text view")
    XCTAssertTrue(app.staticTexts["Ask \(bot)"].exists || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ask '")).firstMatch.exists, "no placeholder")
    shoot("kbd-0-empty")
    input.tap()
    input.typeText("UI test \(marker), first line")
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no on-screen keyboard")
    let returnKey = keyboard.buttons.matching(NSPredicate(format: "label ==[c] 'return' OR identifier ==[c] 'Return'")).firstMatch
    XCTAssertTrue(returnKey.exists, "no Return key on the on-screen keyboard")
    returnKey.tap()
    input.typeText("reply with only the word OK")
    let draft = input.value as? String ?? ""
    XCTAssertTrue(draft.contains("\n"), "the on-screen Return did not add a line: \(draft.debugDescription)")
    XCTAssertFalse(userMessage(containing: marker).exists, "the on-screen Return sent the message")
    shoot("kbd-1-two-lines")

    app.buttons["Send"].tap()
    XCTAssertTrue(userMessage(containing: marker).waitForExistence(timeout: 20), "the message did not send")
    XCTAssertTrue(userMessage(containing: "reply with only the word OK").exists, "the second line was lost")
    XCTAssertEqual(input.value as? String ?? "", "", "the composer kept the text")
    shoot("kbd-2-sent")

    // Clean up: stop the reply if it still runs, archive the chat. A toast over the toolbar
    // eats the first tap, so open the menu until Archive shows.
    let stop = app.buttons["Stop"]
    if stop.exists { stop.tap() }
    let archive = app.buttons["Archive"].firstMatch
    for _ in 0..<4 where !archive.exists {
      app.buttons["More"].firstMatch.tap()
      _ = archive.waitForExistence(timeout: 2)
    }
    archive.tap()
  }
}

/// Settings > Notifications against a real backend: allows notifications when iOS asks, then
/// shows what the Mac said. Read-only apart from registering the simulator with the Mac.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file> \
///   TEST_RUNNER_TALARIA_UITEST_PUSH=1 [TEST_RUNNER_TALARIA_UITEST_MAC_STATE=Ready] \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/NotificationSettingsTests
@MainActor
final class NotificationSettingsTests: XCTestCase {
  private var app: XCUIApplication!
  private var shots: String?
  private var expectedMac: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty, environment["TALARIA_UITEST_PUSH"] != nil else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_PUSH.")
    }
    shots = environment["TALARIA_UITEST_SHOTS"]
    expectedMac = environment["TALARIA_UITEST_MAC_STATE"]
    continueAfterFailure = true
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = server
    app.launchEnvironment["TALARIA_SIGNIN_FILE"] = environment["TALARIA_UITEST_SIGNIN"] ?? ""
    app.launchEnvironment["TALARIA_PUSH_PROMPT"] = "1"
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

  func testSettingsShowWhatTheMacCanSend() throws {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow"]
    if allow.waitForExistence(timeout: 8) { allow.tap() }
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "home did not load")
    // Settings is in the dock on iPhone and in the sidebar on iPad.
    let settings = UIDevice.current.userInterfaceIdiom == .pad ? app.buttons["area.settings"] : app.buttons["dock.settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()
    let mac = app.descendants(matching: .any)["push.mac"]
    XCTAssertTrue(mac.waitForExistence(timeout: 10), "no notifications section")
    // The registration goes out once iOS hands over a token.
    if let expectedMac {
      let deadline = Date().addingTimeInterval(20)
      while Date() < deadline, !mac.label.contains(expectedMac) { sleep(1) }
      XCTAssertTrue(mac.label.contains(expectedMac), "Your Mac says: \(mac.label)")
    } else {
      sleep(5)
    }
    shoot("push-settings")
    app.swipeUp()
    sleep(1)
    shoot("push-settings-2")
  }
}
