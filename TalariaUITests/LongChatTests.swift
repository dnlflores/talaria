import XCTest

/// A long conversation opens on its newest messages and loads older ones as you scroll up.
///
/// Live only: `TEST_RUNNER_TALARIA_UITEST_SERVER` and `TEST_RUNNER_TALARIA_UITEST_LONG_CHAT`
/// (`<profile>/<stored id>` of an idle chat with hundreds of messages). Never point it at a chat
/// that is working: opening it attaches to its live session.
@MainActor
final class LongChatTests: XCTestCase {
  private var app: XCUIApplication!
  private var shots: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty,
      let chat = environment["TALARIA_UITEST_LONG_CHAT"], chat.contains("/")
    else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER and TEST_RUNNER_TALARIA_UITEST_LONG_CHAT to run this.")
    }
    shots = environment["TALARIA_UITEST_SHOTS"]
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchEnvironment["TALARIA_SERVER"] = server
    app.launchEnvironment["TALARIA_SIGNIN_FILE"] = environment["TALARIA_UITEST_SIGNIN"] ?? ""
    app.launchEnvironment["TALARIA_OPEN_CHAT"] = chat
  }

  private func shoot(_ name: String) {
    guard let shots else { return }
    let url = URL(fileURLWithPath: shots).appendingPathComponent("\(name).png")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
  }

  private var content: XCUIElementQuery {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'transcript.answer', 'transcript.user'}"))
  }

  private var userBubbles: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "transcript.user")
  }

  /// Transcript rows with words, and where they are: one snapshot, so a moment can be caught.
  private func visibleRows() throws -> [(label: String, y: CGFloat)] {
    var out: [(label: String, y: CGFloat)] = []
    func walk(_ element: any XCUIElementSnapshot) {
      if ["transcript.answer", "transcript.user"].contains(element.identifier), !element.label.isEmpty {
        out.append((element.label, element.frame.minY))
      }
      for child in element.children { walk(child) }
    }
    walk(try app.snapshot())
    return out
  }

  /// Scrolling up reads older pages: more of the conversation appears above, and what is on
  /// screen when a page lands stays where it is. Pages are slowed down so the moment they land
  /// can be watched.
  func testScrollingUpLoadsOlderMessages() throws {
    app.launchEnvironment["TALARIA_UITEST_PAGE_DELAY"] = "4"
    app.launch()
    XCTAssertTrue(content.firstMatch.waitForExistence(timeout: 90), "the transcript did not show")
    sleep(2)
    let opened = userBubbles.count
    shoot("long-02-opened")
    let earlier = app.descendants(matching: .any).matching(identifier: "transcript.earlier").firstMatch
    XCTAssertTrue(earlier.exists, "a long chat opened without a way to older messages")
    let loading = app.staticTexts["Loading earlier messages"]
    let screen = app.windows.firstMatch.frame
    var landed = 0
    for _ in 0..<30 where earlier.exists && landed < 2 {
      app.swipeDown(velocity: .slow)
      guard loading.waitForExistence(timeout: 1) else { continue }
      // The scroll has stopped and the page is still on its way: note what is on screen.
      usleep(800_000)
      let before = try visibleRows()
      let labels = before.map(\.label)
      guard loading.exists,
        // The row nearest the middle of the screen whose words appear once; it may start above
        // the screen when it is long.
        let watched = before.filter({ row in row.y < screen.maxY - 120 && labels.filter { $0 == row.label }.count == 1 })
          .min(by: { abs($0.y - screen.midY) < abs($1.y - screen.midY) })
      else { continue }
      let usersBefore = userBubbles.count
      shoot("long-03-page-on-its-way-\(landed)")
      XCTAssertTrue(loading.waitForNonExistence(timeout: 60), "the page never landed")
      usleep(600_000)
      let after = try visibleRows()
      guard let same = after.first(where: { $0.label == watched.label }) else {
        XCTFail("the row on screen is gone after the page landed")
        break
      }
      let moved = same.y - watched.y
      print(String(format: "POSITION page landed: watched row moved %.0f pt; rows with words %d -> %d; user messages %d -> %d",
                   moved, before.count, after.count, usersBefore, userBubbles.count))
      shoot("long-04-page-landed-\(landed)")
      XCTAssertLessThan(abs(moved), 30, "what was on screen jumped when older messages arrived")
      landed += 1
    }
    XCTAssertGreaterThan(landed, 0, "scrolling up loaded nothing older")
    for _ in 0..<40 where earlier.exists && userBubbles.count <= opened { app.swipeDown(velocity: .fast) }
    XCTAssertGreaterThan(userBubbles.count, opened, "no older messages appeared above")
  }

  func testOpensQuickly() throws {
    let start = Date()
    app.launch()
    XCTAssertTrue(content.firstMatch.waitForExistence(timeout: 90), "the transcript did not show")
    print(String(format: "TIMING open-to-content: %.2f s", Date().timeIntervalSince(start)))
    shoot("long-01-open")
  }
}
