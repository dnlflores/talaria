import XCTest

/// Ways around the app shared by the UI tests. Both docks hold Chats and Agents only: Settings is
/// in the inbox's corner, and New chat, Cron and Kanban open per bot.
@MainActor
extension XCUIApplication {
  /// The inbox's Settings button, there once home has loaded.
  var homeSettings: XCUIElement { buttons["home.settings"] }

  /// Waits for the inbox to load.
  func waitForHome(timeout: TimeInterval = 30) -> Bool {
    homeSettings.waitForExistence(timeout: timeout)
  }

  /// Agents in the side dock (iPad, an unfolded iPhone Duo) or the iPhone dock.
  func openAgents() {
    let side = buttons["area.agents"]
    if side.exists { side.tap() } else { buttons["dock.agents"].tap() }
  }

  /// A bot's hub: its row in the Agents list in the split view, else the switcher's avatar.
  func openHub(_ bot: String) {
    openAgents()
    let isSplit = UIDevice.current.userInterfaceIdiom == .pad && frame.width >= 800
    if isSplit {
      let row = buttons.matching(NSPredicate(format: "identifier == 'bot.row' AND label BEGINSWITH %@", bot)).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10), "\(bot) is not in the Agents list")
      row.tap()
    } else {
      let avatar = buttons.matching(NSPredicate(format: "identifier == 'agent.switch' AND label == %@", bot)).firstMatch
      XCTAssertTrue(avatar.waitForExistence(timeout: 10), "\(bot) is not in the switcher")
      // Bots beyond the screen's edge are a swipe away.
      for _ in 0..<8 where !frame.insetBy(dx: 20, dy: 0).contains(avatar.frame) {
        let picked = buttons.matching(NSPredicate(format: "identifier == 'agent.switch' AND isSelected == true")).firstMatch
        if avatar.frame.midX < frame.midX { picked.swipeRight(velocity: .slow) } else { picked.swipeLeft(velocity: .slow) }
        sleep(1)
      }
      avatar.tap()
      XCTAssertTrue(staticTexts[bot].waitForExistence(timeout: 5), "the hub does not show \(bot)")
    }
    XCTAssertTrue(buttons["hub.model"].waitForExistence(timeout: 10), "the hub did not open")
  }

  /// Chats in the side dock or the iPhone dock.
  func openChats() {
    let side = buttons["area.chats"]
    if side.exists { side.tap() } else { buttons["dock.chats"].tap() }
  }

  /// Settings from the inbox's corner.
  func openSettings() {
    homeSettings.tap()
  }

  /// A new chat with `bot`, from its row's menu in the inbox, so it stacks on Chats (the hub's
  /// New chat would stack it on Agents).
  func startNewChat(with bot: String) {
    let row = buttons.matching(NSPredicate(
      format: "identifier == 'session.row' AND (label BEGINSWITH %@ OR label == %@)", "\(bot),", bot)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20), "\(bot) is not in the inbox")
    row.press(forDuration: 1.2)
    let item = buttons["New chat with \(bot)"].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no New chat in \(bot)'s menu")
    item.tap()
  }
}
