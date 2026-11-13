import XCTest

/// Offline regression tests of the production transcript's jump-to-latest button.
@MainActor
final class TranscriptScrollTests: XCTestCase {
  private var app: XCUIApplication!
  private var transcript: XCUIElement { app.scrollViews["transcript.scroll"] }
  private var jump: XCUIElement { app.buttons["Jump to latest"] }
  private var latest: XCUIElement { app.staticTexts["Latest reply. Everything is up to date."] }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview"]
  }

  private func launch() {
    app.launch()
    XCTAssertTrue(latest.waitForExistence(timeout: 10))
    XCTAssertTrue(latest.isHittable, "the chat should open at its latest reply")
    XCTAssertFalse(jump.exists, "no jump button at the bottom")
  }

  private func shoot(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let path = ProcessInfo.processInfo.environment["TALARIA_UITEST_SHOTS"] {
      let directory = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
  }

  /// A held drag has no fling, so a small movement stays well below a screenful.
  private func drag(from: CGFloat, to: CGFloat) {
    transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
      .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
             withVelocity: .slow, thenHoldForDuration: 0.3)
  }

  func testSmallScrollDoesNotShowJumpButton() {
    launch()
    let before = latest.frame.minY
    drag(from: 0.4, to: 0.6)
    let moved = latest.frame.minY - before
    XCTAssertGreaterThan(moved, 60, "the drag must leave the auto-follow tolerance")
    XCTAssertLessThan(moved, transcript.frame.height * 0.6, "the drag must stay under one viewport")
    shoot("scroll-less-than-one-screen")
    XCTAssertFalse(jump.exists, "the button must stay hidden less than a screen from the bottom")
  }

  func testExpandingAndCollapsingToolsAtBottomDoesNotShowJumpButton() {
    launch()
    let work = app.buttons["transcript.work"].firstMatch
    XCTAssertTrue(work.isHittable)
    work.tap()
    XCTAssertTrue(app.buttons["transcript.tool.scroll-preview-tool"].exists)
    shoot("scroll-tools-expanded-at-bottom")
    XCTAssertFalse(jump.exists, "expanding a short tool log must not show the button")
    work.tap()
    XCTAssertFalse(app.buttons["transcript.tool.scroll-preview-tool"].exists)
    shoot("scroll-tools-collapsed-at-bottom")
    XCTAssertFalse(jump.exists, "the button must be hidden after collapsing back to the bottom")
  }

  func testJumpAppearsFarAwayAndHidesWhenReturningToBottom() {
    launch()
    for _ in 0..<4 { drag(from: 0.25, to: 0.65) }
    shoot("scroll-more-than-one-screen")
    XCTAssertTrue(jump.exists, "the button must appear more than a screen from the bottom")
    for _ in 0..<2 { drag(from: 0.65, to: 0.25) }
    shoot("scroll-back-within-one-screen")
    XCTAssertFalse(jump.exists, "the button must hide within a screen, before reaching the bottom")
    for _ in 0..<2 { drag(from: 0.65, to: 0.25) }
    XCTAssertTrue(latest.isHittable)
    shoot("scroll-returned-to-bottom")
    XCTAssertFalse(jump.exists, "scrolling back down must hide the button")
    for _ in 0..<4 { drag(from: 0.25, to: 0.65) }
    XCTAssertTrue(jump.exists)
    jump.tap()
    XCTAssertTrue(jump.waitForNonExistence(timeout: 3))
    XCTAssertTrue(latest.isHittable, "jumping must reach the latest reply")
    shoot("scroll-jumped-to-latest")
  }

  func testShortChatAndBottomBounceNeverShowJumpButton() {
    app.launchArguments.append("--short-chat")
    launch()
    drag(from: 0.7, to: 0.3)
    XCTAssertFalse(jump.exists)
    app.buttons["transcript.work"].firstMatch.tap()
    shoot("scroll-short-chat")
    XCTAssertFalse(jump.exists, "a chat shorter than the viewport never needs a jump button")
  }
}
