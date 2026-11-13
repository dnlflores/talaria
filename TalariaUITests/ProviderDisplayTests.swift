import XCTest

@MainActor
final class ProviderDisplayTests: XCTestCase {
  func testGPTAndClaudeUpdatesAreReadableWithToolsCollapsed() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--transcript-preview", "--provider-display"]
    app.launch()
    let gpt = app.staticTexts["GPT: I found the cause. This progress message stays readable outside the tools."]
    let claude = app.staticTexts["Claude: I found the cause. This progress message stays readable outside the tools."]
    XCTAssertTrue(gpt.waitForExistence(timeout: 10))
    XCTAssertTrue(claude.exists)
    XCTAssertTrue(app.staticTexts["GPT: The fix is ready."].exists)
    XCTAssertTrue(app.staticTexts["Claude: The fix is ready."].exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'internal plumbing'")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Private GPT'")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Private Claude'")).firstMatch.exists)
    XCTAssertFalse(app.buttons["transcript.tool.provider-gpt"].exists)
    XCTAssertFalse(app.buttons["transcript.tool.provider-claude"].exists)
    func shoot(_ name: String) {
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
    shoot("provider-messages-portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(gpt.isHittable)
    XCTAssertTrue(claude.isHittable)
    shoot("provider-messages-landscape")
  }
}
