import XCTest

@MainActor
final class ThinkingMarkdownTests: XCTestCase {
  func testThinkingRendersBoldMarkersInsteadOfDisplayingAsterisks() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--transcript-preview"]
    app.launch()
    let thought = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'A small, focused change'")).firstMatch
    XCTAssertTrue(thought.waitForExistence(timeout: 10))
    XCTAssertFalse(thought.label.contains("**"), "bold Markdown markers should not appear as literal text")
    XCTAssertTrue(thought.label.contains("Check one change at a time."), "keep separate paragraphs readable")
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "thinking-without-literal-markdown"
    attachment.lifetime = .keepAlways
    add(attachment)
    if let path = ProcessInfo.processInfo.environment["TALARIA_UITEST_SHOTS"] {
      let directory = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("thinking-without-literal-markdown.png"))
    }
  }
}
