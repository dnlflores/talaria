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
    let bottomY = latest.frame.minY
    let height = transcript.frame.height
    for _ in 0..<4 { drag(from: 0.25, to: 0.65) }
    XCTAssertGreaterThan(latest.frame.minY - bottomY, height, "the test must scroll at least a screen away")
    shoot("scroll-more-than-one-screen")
    XCTAssertTrue(jump.exists, "the button must appear more than a screen from the bottom")
    // Opposite drags need not cover equal distances (touch slop and scroll deceleration).
    // Measure the latest row's displacement rather than guessing from the gesture count.
    for _ in 0..<12 where latest.frame.minY - bottomY > height * 0.4 {
      drag(from: 0.65, to: 0.5)
    }
    let remaining = latest.frame.minY - bottomY
    XCTAssertGreaterThan(remaining, 60, "the test must still be away from the bottom")
    XCTAssertLessThan(remaining, height * 0.5, "the test must be comfortably within one screen")
    shoot("scroll-back-within-one-screen")
    XCTAssertFalse(jump.exists, "the button must hide within a screen, before reaching the bottom")
    for _ in 0..<4 where latest.frame.minY - bottomY > 5 { drag(from: 0.65, to: 0.25) }
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

  // MARK: Following a running turn (`--live-turns` plays turns through the real event handling)

  private func launchLive(shortChat: Bool, paceMilliseconds: Int = 60) {
    app.launchArguments.append("--live-turns")
    if shortChat { app.launchArguments.append("--short-chat") }
    app.launchEnvironment["TALARIA_LIVE_TURNS_DELAY"] = "4"
    app.launchEnvironment["TALARIA_LIVE_TURNS_PACE_MS"] = String(paceMilliseconds)
    launch()
  }

  private func waitForText(_ needle: String, timeout: TimeInterval = 40) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
      .waitForExistence(timeout: timeout)
  }

  /// One consistent reading of where the transcript's content ends and where the composer (or the
  /// queue panel above it) starts.
  private func endAndComposer() -> (end: CGFloat, composer: CGFloat)? {
    guard let root = try? app.snapshot() else { return nil }
    var end: CGFloat = 0
    var composer = CGFloat.greatestFiniteMagnitude
    var stack: [any XCUIElementSnapshot] = [root]
    while let node = stack.popLast() {
      let id = node.identifier
      if id.hasPrefix("transcript."), id != "transcript.scroll", id != "transcript.earlier" {
        end = max(end, node.frame.maxY)
      } else if id == "composer.input" || id == "queue.panel" {
        composer = min(composer, node.frame.minY)
      }
      stack.append(contentsOf: node.children)
    }
    return composer < .greatestFiniteMagnitude ? (end, composer) : nil
  }

  /// Samples the end of the transcript while the turn streams: it must stay above the composer.
  private func assertFollows(_ moment: String, samples: Int = 5, file: StaticString = #filePath, line: UInt = #line) {
    for sample in 0..<samples {
      guard let reading = endAndComposer() else { return XCTFail("no transcript reading", file: file, line: line) }
      XCTAssertLessThanOrEqual(
        reading.end, reading.composer + 1,
        "\(moment), sample \(sample): the newest content is under the composer", file: file, line: line)
    }
  }

  func testLiveTurnStaysInSightAboveTheComposer() {
    launchLive(shortChat: false)
    // The queued message shows from the first turn's second step until the turn ends.
    XCTAssertTrue(app.descendants(matching: .any)["queue.panel"].waitForExistence(timeout: 30))
    assertFollows("running steps with a queued message")
    XCTAssertTrue(waitForText("Paragraph 2 of the answer"))
    assertFollows("streaming the answer")
    shoot("follow-live-turn")
    XCTAssertFalse(jump.exists)
  }

  /// A chat between one and two screens tall used to stop following once it had been scrolled,
  /// because the bottom was also "near the top", where reading back is assumed.
  func testShortChatKeepsFollowingAfterAScroll() {
    launchLive(shortChat: true)
    drag(from: 0.7, to: 0.4)
    XCTAssertTrue(waitForText("Paragraph 2 of the answer"))
    assertFollows("streaming the answer")
    XCTAssertTrue(waitForText("Live question 2"))
    assertFollows("next turn")
    shoot("follow-short-chat")
    XCTAssertFalse(jump.exists)
  }

  func testReadingBackIsNotMovedByALiveTurn() {
    // Slow enough that the first turn is still streaming after the drags.
    launchLive(shortChat: false, paceMilliseconds: 150)
    XCTAssertTrue(waitForText("Live question 1"))
    for _ in 0..<4 { drag(from: 0.25, to: 0.65) }
    XCTAssertTrue(jump.exists, "the test must be more than a screen up")
    let before = latest.frame.minY
    sleep(3)
    XCTAssertEqual(latest.frame.minY, before, accuracy: 2, "what is being read must not move while the turn streams")
    shoot("follow-reading-back")
    jump.tap()
    XCTAssertTrue(jump.waitForNonExistence(timeout: 3))
    assertFollows("after jumping back")
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
