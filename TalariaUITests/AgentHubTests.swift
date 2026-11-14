import XCTest

/// The agent hub's writes, against a real backend:
/// - a star in All models reaches the Mac's shared UI preferences (where the desktop app keeps its
///   favourite models), shows under Favourites, and comes off again;
/// - the bot's default model changes from its Default Model page and is put back.
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file from scripts/sign-in.py> \
///   TEST_RUNNER_TALARIA_UITEST_HUB_BOT=<bot title> \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/AgentHubTests
///
/// The default-model test writes the bot's config.yaml twice (another model, then the one it had).
/// Back that file up before a run and compare it after. No model calls are made.
@MainActor
final class AgentHubTests: XCTestCase {
  private var app: XCUIApplication!
  private var bot = ""
  private var server = ""
  private var signInFile = ""
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty,
      let bot = environment["TALARIA_UITEST_HUB_BOT"], !bot.isEmpty
    else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_HUB_BOT to run the hub flow.")
    }
    self.bot = bot
    self.server = server
    signInFile = environment["TALARIA_UITEST_SIGNIN"] ?? ""
    shots = environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = server
    app.launchEnvironment["TALARIA_SIGNIN_FILE"] = signInFile
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
      try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots).appendingPathComponent("hub-\(name).png"))
    }
  }

  /// The split view (a full-size iPad) lists the bots; one stack shows the hub with a switcher.
  private var isSplit: Bool {
    UIDevice.current.userInterfaceIdiom == .pad && app.frame.width >= 800
  }

  /// The bot's hub: the switcher in one stack, its row in the Agents list in the split view.
  private func openHub() {
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 30), "home did not load")
    // The side dock (iPad, an unfolded iPhone Duo) or the iPhone dock.
    let sideDock = app.buttons["area.agents"]
    if sideDock.exists { sideDock.tap() } else { app.buttons["dock.agents"].tap() }
    if isSplit {
      let row = app.buttons.matching(NSPredicate(format: "identifier == 'bot.row' AND label BEGINSWITH %@", bot)).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10), "\(bot) is not in the Agents list")
      row.tap()
    } else {
      let avatar = app.buttons.matching(NSPredicate(format: "identifier == 'agent.switch' AND label == %@", bot)).firstMatch
      XCTAssertTrue(avatar.waitForExistence(timeout: 10), "\(bot) is not in the switcher")
      // Bots beyond the screen's edge are a swipe away.
      for _ in 0..<8 where !app.frame.insetBy(dx: 20, dy: 0).contains(avatar.frame) {
        let picked = app.buttons.matching(NSPredicate(format: "identifier == 'agent.switch' AND isSelected == true")).firstMatch
        if avatar.frame.midX < app.frame.midX { picked.swipeRight(velocity: .slow) } else { picked.swipeLeft(velocity: .slow) }
        sleep(1)
      }
      avatar.tap()
      XCTAssertTrue(app.staticTexts[bot].waitForExistence(timeout: 5), "the hub does not show \(bot)")
    }
    XCTAssertTrue(app.buttons["hub.model"].waitForExistence(timeout: 10), "the hub did not open")
    sleep(1)
  }

  private func goBack() {
    let back = app.buttons["BackButton"].firstMatch
    if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    sleep(1)
  }

  /// The favourites the Mac holds, read the way the desktop app does.
  private func macFavourites() throws -> [String] {
    let tokens = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: signInFile))) as? [String: Any]
    var request = URLRequest(url: URL(string: server + "/api/ui-preferences")!)
    if let token = tokens?["access_token"] as? String { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let done = expectation(description: "ui-preferences")
    var body: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      body = data
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 20)
    let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
    let values = json?["values"] as? [String: Any]
    guard let raw = values?["hermes.desktop.favorite-models"] as? String else { return [] }
    return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String]) ?? []
  }

  private func waitForMac(_ expected: @escaping ([String]) -> Bool, timeout: TimeInterval = 20) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if expected(try macFavourites()) { return true }
      sleep(1)
    }
    return false
  }

  func testStarReachesTheMacAndComesOff() throws {
    openHub()
    let before = try macFavourites()
    app.buttons["hub.model"].tap()
    XCTAssertTrue(app.buttons["model.all"].waitForExistence(timeout: 20))
    app.buttons["model.all"].tap()
    let star = app.buttons.matching(NSPredicate(format: "identifier == 'model.star' AND label BEGINSWITH 'Add '")).firstMatch
    XCTAssertTrue(star.waitForExistence(timeout: 60), "no model to star")
    let name = star.label.replacingOccurrences(of: "Add ", with: "").replacingOccurrences(of: " to favourites", with: "")
    star.tap()
    let starred = app.buttons.matching(
      NSPredicate(format: "identifier == 'model.star' AND label == %@", "Remove \(name) from favourites")).firstMatch
    XCTAssertTrue(starred.waitForExistence(timeout: 5), "the star did not fill")
    XCTAssertTrue(try waitForMac { $0.count == before.count + 1 }, "the star never reached the Mac")
    shoot("01-starred")

    // Under Favourites on the Default Model page, then off again from there.
    goBack()
    let favourite = app.buttons.matching(NSPredicate(format: "identifier == 'model.row' AND label BEGINSWITH %@", "\(name),")).firstMatch
    XCTAssertTrue(favourite.waitForExistence(timeout: 5), "\(name) is not under Favourites")
    shoot("02-favourites")
    starred.tap()
    XCTAssertTrue(favourite.waitForNonExistence(timeout: 5), "\(name) stayed under Favourites")
    XCTAssertTrue(try waitForMac { $0 == before }, "the Mac kept the star")
  }

  /// Read-only: the constellation draws only the bot's memories, each under a short title, a star
  /// shows its links, and a memory opens in full.
  func testMemoryShowsTheConstellation() throws {
    openHub()
    let memory = app.buttons["hub.memory"]
    XCTAssertTrue(memory.waitForExistence(timeout: 5))
    memory.tap()
    let header = app.descendants(matching: .any)["constellation.header"]
    XCTAssertTrue(header.waitForExistence(timeout: 30), "no constellation")
    let stars = app.buttons.matching(identifier: "constellation.star")
    XCTAssertGreaterThan(stars.count, 0, "no stars drawn")
    // The count in the header is the number of stars, and every star is a memory, none a skill.
    XCTAssertTrue(header.label.hasSuffix("\(stars.count)"), "header \(header.label) vs \(stars.count) stars")
    let notes = app.buttons.matching(identifier: "learning.note")
    XCTAssertFalse(app.buttons.matching(identifier: "learning.skill").firstMatch.exists, "skills are listed")
    // Each star's title is the memory's first few words.
    for star in stars.allElementsBoundByIndex {
      let label = star.label
      XCTAssertTrue(label.hasSuffix(", memory") || label.hasSuffix(", about you"), "not a memory: \(label)")
      let title = label.components(separatedBy: ", ").dropLast().joined(separator: ", ")
      XCTAssertLessThanOrEqual(title.split(separator: " ").count, 6, "not a title: \(title)")
    }
    shoot("05-constellation")
    // The map's own frame spans every star, drawn or not; the card shows the 470 points under its
    // header. A star's frame takes in its name, so its disc is the top 40 points.
    let shown = CGRect(x: header.frame.minX, y: header.frame.maxY, width: header.frame.width, height: 470)
      .insetBy(dx: 30, dy: 30)
    // Every title fits on the card: no star's disc lies outside it.
    let card = CGRect(x: header.frame.minX, y: header.frame.maxY, width: header.frame.width, height: 470)
    for star in stars.allElementsBoundByIndex {
      XCTAssertTrue(card.contains(CGPoint(x: star.frame.midX, y: star.frame.minY + 20)), "\(star.label) is off the card")
    }
    let star = stars.allElementsBoundByIndex.first { shown.contains(CGPoint(x: $0.frame.midX, y: $0.frame.minY + 20)) }
    XCTAssertNotNil(star, "no star on screen")
    star?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).tap()
    let picked = app.buttons["constellation.selected"]
    XCTAssertTrue(picked.waitForExistence(timeout: 5), "picking a star showed nothing")
    XCTAssertTrue(picked.label.contains("link"), "no links named: \(picked.label)")
    shoot("06-star")
    picked.tap()
    // The memory's text in full.
    XCTAssertTrue(app.descendants(matching: .any)["learning.content"].waitForExistence(timeout: 20), "the node did not open")
    shoot("07-node")
    goBack()
    // The list under the map has the same memories.
    XCTAssertTrue(notes.firstMatch.waitForExistence(timeout: 5), "no memory list")
    XCTAssertEqual(notes.count, stars.count, "the list and the map disagree")
    shoot("08-memory-list")

    // On iPad the card changes shape when it turns, and the web is laid out again to fit it.
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCUIDevice.shared.orientation = .landscapeLeft
      defer { XCUIDevice.shared.orientation = .portrait }
      sleep(3)
      let turned = CGRect(x: header.frame.minX, y: header.frame.maxY, width: header.frame.width, height: 470)
      for star in stars.allElementsBoundByIndex where star.frame.minY < app.frame.maxY {
        XCTAssertTrue(turned.contains(CGPoint(x: star.frame.midX, y: star.frame.minY + 20)), "\(star.label) is off the turned card")
      }
      shoot("09-constellation-landscape")
    }
  }

  func testDefaultModelChangesAndComesBack() throws {
    openHub()
    app.buttons["hub.model"].tap()
    let current = app.descendants(matching: .any)["model.current"]
    XCTAssertTrue(current.waitForExistence(timeout: 20))
    // "In use: Opus 5.5, Anthropic"
    let original = current.label.replacingOccurrences(of: "In use: ", with: "").components(separatedBy: ",").first ?? ""
    XCTAssertFalse(original.isEmpty || original == "Not set", "no default model to start from")

    func pick(_ predicate: NSPredicate) -> String {
      app.buttons["model.all"].tap()
      let inUse = app.buttons.matching(NSPredicate(format: "identifier == 'model.provider' AND label CONTAINS 'In use'")).firstMatch
      XCTAssertTrue(inUse.waitForExistence(timeout: 60), "no provider marked in use")
      let row = app.buttons.matching(identifier: "model.row").matching(predicate).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10), "no model to pick")
      let picked = row.label.components(separatedBy: ",").first ?? row.label
      row.tap()
      let useIt = app.alerts.buttons["Use it"]
      if useIt.waitForExistence(timeout: 4) { useIt.tap() }
      return picked
    }

    let other = pick(NSPredicate(format: "NOT (label CONTAINS 'in use') AND isEnabled == true"))
    let switched = NSPredicate(format: "label BEGINSWITH %@", "In use: \(other),")
    expectation(for: switched, evaluatedWith: current)
    waitForExpectations(timeout: 30)
    shoot("03-default-changed")
    goBack()
    XCTAssertTrue(app.buttons["hub.model"].label.contains(other), "the hub row does not show \(other): \(app.buttons["hub.model"].label)")

    // Put the bot back on its model.
    app.buttons["hub.model"].tap()
    XCTAssertTrue(current.waitForExistence(timeout: 10))
    _ = pick(NSPredicate(format: "label BEGINSWITH %@", "\(original),"))
    expectation(for: NSPredicate(format: "label BEGINSWITH %@", "In use: \(original),"), evaluatedWith: current)
    waitForExpectations(timeout: 30)
    shoot("04-default-restored")
  }
}
