import XCTest

/// What each edit changed: counts on the file chips and in the Files list, the Changes view of an
/// edited file, and the colored diff in a tool's details. Offline, through the production chat.
@MainActor
final class EditedFilesTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--scroll-preview", "--short-chat", "--edited-files"]
    if let appearance = ProcessInfo.processInfo.environment["TALARIA_UITEST_APPEARANCE"] {
      app.launchEnvironment["TALARIA_PREVIEW_APPEARANCE"] = appearance
    }
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

  private func diffLine(_ label: String) -> XCUIElement {
    app.staticTexts.matching(identifier: "diff.line").matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
  }

  private func chip(_ name: String) -> XCUIElement {
    app.buttons.matching(identifier: "transcript.file").matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
  }

  func testEditedFilesShowWhatChanged() {
    app.launch()
    XCTAssertTrue(app.staticTexts["Updated the greeting in two places and wrote the notes."].waitForExistence(timeout: 10))

    // Two edits to one file add up on its chip; the new file counts its written lines.
    let swift = chip("Greeting.swift")
    let notes = chip("notes.md")
    XCTAssertTrue(swift.exists)
    XCTAssertTrue(swift.label.contains("4 lines added, 2 removed"), swift.label)
    XCTAssertTrue(notes.label.contains("4 lines added, 0 removed"), notes.label)
    shoot("1-chips-with-counts")

    // An edited file opens on its changes, one edit after another.
    swift.tap()
    let changes = app.buttons["Changes"]
    XCTAssertTrue(changes.waitForExistence(timeout: 5))
    XCTAssertTrue(changes.isSelected, "an edited file opens on Changes")
    XCTAssertTrue(app.staticTexts["Edit 1"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Edit 2"].exists)
    XCTAssertTrue(diffLine("Removed: func greet(_ name: String) -> String {").exists)
    XCTAssertTrue(diffLine("Added:   let subtitle: String").exists)
    shoot("2-changes-two-edits")
    app.buttons["File"].tap()
    XCTAssertFalse(app.scrollViews["file.changes"].exists, "File shows the file, not the diff")
    app.buttons["Done"].tap()

    // A long added line wraps inside the screen instead of scrolling sideways.
    XCTAssertTrue(notes.waitForExistence(timeout: 5))
    notes.tap()
    let long = diffLine("Added: The Changes view wraps a long line")
    XCTAssertTrue(long.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Edit 1"].exists, "one edit needs no label")
    let window = app.windows.firstMatch.frame
    XCTAssertLessThanOrEqual(long.frame.maxX, window.maxX)
    XCTAssertGreaterThan(long.frame.height, 30, "the long line wraps onto several lines")
    shoot("3-changes-long-line-wrapped")
    app.buttons["Done"].tap()

    // The chat's Files list shows the same counts.
    app.buttons["More"].tap()
    let files = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Files'")).firstMatch
    XCTAssertTrue(files.waitForExistence(timeout: 5))
    files.tap()
    let row = app.buttons.matching(identifier: "files.row").matching(NSPredicate(format: "label CONTAINS 'Greeting.swift'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    XCTAssertTrue(row.label.contains("4 lines added, 2 removed"), row.label)
    shoot("4-files-sheet-counts")
    app.buttons["Done"].tap()

    // A tool's details color its diff the same way.
    let log = app.buttons.matching(identifier: "transcript.work").firstMatch
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    log.tap()
    let edit = app.buttons["transcript.tool.edit-1"]
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    XCTAssertTrue(app.staticTexts["DIFF"].waitForExistence(timeout: 5))
    XCTAssertTrue(diffLine("Removed:   \"Hello, \\(name)\"").exists)
    XCTAssertTrue(diffLine("File: a/Sources/App/Greeting.swift → b/Sources/App/Greeting.swift").exists)
    shoot("5-tool-detail-diff")
  }
}
