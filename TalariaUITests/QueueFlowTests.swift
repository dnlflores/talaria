import XCTest

/// Messages sent while the agent works wait in a queue above the composer; "Send now" puts one
/// into the running reply. Runs against a real backend, like `LiveFlowTests`:
///
///   TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
///   TEST_RUNNER_TALARIA_UITEST_SIGNIN=<tokens file from scripts/sign-in.py> \
///   TEST_RUNNER_TALARIA_UITEST_BOT=<bot title> \
///   xcodebuild test-without-building ... -only-testing:TalariaUITests/QueueFlowTests
///
/// `testPicturesShow` also needs `TEST_RUNNER_TALARIA_UITEST_PICTURE_CHAT`: the title of a chat
/// whose user message has an attached picture and whose reply delivers one with a `MEDIA:` line.
@MainActor
final class QueueFlowTests: XCTestCase {
  private var app: XCUIApplication!
  private var bot = "Hermes"
  private var shots: String?
  private var pictureChat: String?

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["TALARIA_UITEST_SERVER"], !server.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_SERVER to run the live flow.")
    }
    bot = environment["TALARIA_UITEST_BOT"] ?? "Hermes"
    shots = environment["TALARIA_UITEST_SHOTS"]
    pictureChat = environment["TALARIA_UITEST_PICTURE_CHAT"]
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

  private var input: XCUIElement {
    app.textViews["composer.input"].firstMatch
  }

  private func type(_ text: String, then button: String) {
    XCTAssertTrue(input.waitForExistence(timeout: 20), "composer input")
    input.tap()
    input.typeText(text)
    let send = app.buttons[button]
    XCTAssertTrue(send.waitForExistence(timeout: 5), "no \(button) button")
    send.tap()
  }

  private func answer(containing needle: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'transcript.answer' AND label CONTAINS[c] %@", needle)).firstMatch
  }

  private func userMessage(containing needle: String) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier == 'transcript.user' AND label CONTAINS %@", needle))
  }

  private var queueRows: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "queue.row")
  }

  func testQueuedMessagesWaitAndSendNowJoinsTheReply() throws {
    let compose = app.buttons["New chat"]
    XCTAssertTrue(compose.waitForExistence(timeout: 30), "home did not load")
    compose.tap()
    let botRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", bot)).firstMatch
    if botRow.waitForExistence(timeout: 10) { botRow.tap() }

    // A reply that takes a while: a slow command.
    let marker = "queue-\(Int(Date().timeIntervalSince1970) % 100_000)"
    type("UI test \(marker). Run this in the terminal and tell me what it printed: sleep 40; echo kestrel-$((1+1))", then: "Send")
    let running = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'transcript.working' AND label CONTAINS 'Running a command'")).firstMatch
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the command never showed as running")

    // While it runs, the composer queues instead of sending, and says so.
    type("After that, reply with only the word MANGO.", then: "Queue")
    XCTAssertTrue(queueRows.firstMatch.waitForExistence(timeout: 5), "the message did not show as queued")
    XCTAssertTrue(app.staticTexts["1 queued"].exists || app.staticTexts["1 QUEUED"].exists, "no queue count")
    XCTAssertEqual(userMessage(containing: "MANGO").count, 0, "a queued message went into the transcript")
    type("Change of plan: do not wait for the command. Reply with only the word PINEAPPLE.", then: "Queue")
    XCTAssertEqual(queueRows.count, 2)
    XCTAssertTrue(running.exists, "queueing interrupted the running reply")
    shoot("q1-two-queued")

    // Send now: the running reply takes the second message in and answers it.
    let sendNow = app.buttons.matching(identifier: "queue.sendNow")
    XCTAssertEqual(sendNow.count, 2)
    sendNow.element(boundBy: 1).tap()
    XCTAssertTrue(userMessage(containing: "PINEAPPLE").firstMatch.waitForExistence(timeout: 20), "the sent message is not in the transcript")
    XCTAssertEqual(queueRows.count, 1, "the sent message is still queued")
    shoot("q2-sent-now")
    XCTAssertTrue(answer(containing: "PINEAPPLE").waitForExistence(timeout: 30), "the reply did not answer the message sent into it")
    shoot("q3-answered")

    // When that reply ends, the message still queued goes out as the next turn.
    XCTAssertTrue(answer(containing: "MANGO").waitForExistence(timeout: 120), "the queued message never went out")
    XCTAssertTrue(queueRows.firstMatch.waitForNonExistence(timeout: 5), "the queue did not empty")
    XCTAssertEqual(userMessage(containing: "MANGO").count, 1)
    XCTAssertEqual(userMessage(containing: "PINEAPPLE").count, 1)
    shoot("q4-queue-drained")

    // Stop pauses the queue: nothing queued starts on its own until resumed or sent by hand.
    type("Run this in the terminal and tell me what it printed: sleep 30; echo osprey-$((2+2))", then: "Send")
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the second command never showed as running")
    type("Then reply with only the word KIWI.", then: "Queue")
    XCTAssertTrue(queueRows.firstMatch.waitForExistence(timeout: 5))
    app.buttons["Stop"].tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "queue.resume").firstMatch.waitForExistence(timeout: 30), "stopping did not pause the queue")
    XCTAssertTrue(running.waitForNonExistence(timeout: 30), "the reply did not stop")
    sleep(4)
    XCTAssertEqual(userMessage(containing: "KIWI").count, 0, "a paused queue sent on its own")
    shoot("q5-paused")
    app.descendants(matching: .any).matching(identifier: "queue.resume").firstMatch.tap()
    // Sent as its own turn. (The answer itself can fold into the next steps at once: the command
    // the first "Send now" moved to the background reports back with a turn of its own. On the
    // gateway that report is queued behind the stopped reply and runs right after it, so the
    // resumed message waits for it to end first.)
    XCTAssertTrue(userMessage(containing: "KIWI").firstMatch.waitForExistence(timeout: 150), "resuming did not send the queued message")
    XCTAssertTrue(queueRows.firstMatch.waitForNonExistence(timeout: 5), "the queue did not empty")
    shoot("q6-resumed")

    // Clean up: archive the chat.
    app.buttons["More"].firstMatch.tap()
    app.buttons["Archive"].firstMatch.tap()
  }

  func testQueueGoesToTheMacWhenThePhoneSleeps() throws {
    let compose = app.buttons["New chat"]
    XCTAssertTrue(compose.waitForExistence(timeout: 30), "home did not load")
    compose.tap()
    let botRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", bot)).firstMatch
    if botRow.waitForExistence(timeout: 10) { botRow.tap() }
    let running = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'transcript.working' AND label CONTAINS 'Running a command'")).firstMatch
    let onMac = app.descendants(matching: .any).matching(identifier: "queue.onMac")

    // 1. A short sleep: back while the reply still runs. The message waits on the Mac, out of the
    // transcript, and shows up as the next turn's message, after the reply it waited for.
    let marker = "sleep-\(Int(Date().timeIntervalSince1970) % 100_000)"
    type("UI test \(marker). Run this in the terminal and tell me what it printed: sleep 25; echo wren-$((3+3))", then: "Send")
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the command never showed as running")
    type("Then reply with only the word PLUM.", then: "Queue")
    XCTAssertTrue(queueRows.firstMatch.waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)
    sleep(6)
    app.activate()
    XCTAssertTrue(onMac.firstMatch.waitForExistence(timeout: 10), "the queued message was not handed to the Mac")
    XCTAssertEqual(userMessage(containing: "PLUM").count, 0, "a message waiting on the Mac is already in the transcript")
    shoot("s1-on-mac")
    XCTAssertTrue(answer(containing: "PLUM").waitForExistence(timeout: 120), "the handed-over message never ran")
    XCTAssertFalse(onMac.firstMatch.exists, "still shown as waiting on the Mac")
    let plum = userMessage(containing: "PLUM")
    XCTAssertEqual(plum.count, 1, "the handed-over message shows more than once")
    let wren = answer(containing: "wren-6")
    XCTAssertTrue(wren.exists, "the reply it waited for is not shown as an answer")
    XCTAssertGreaterThan(plum.firstMatch.frame.minY, wren.frame.minY, "the handed-over message is not after the reply it waited for")
    shoot("s2-back-while-running")

    // 2. A long sleep: both turns end while the app is away.
    type("Run this in the terminal and tell me what it printed: sleep 20; echo finch-$((4+4))", then: "Send")
    XCTAssertTrue(running.waitForExistence(timeout: 90), "the second command never showed as running")
    type("Then reply with only the word FIG.", then: "Queue")
    XCTAssertTrue(queueRows.firstMatch.waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)
    sleep(60)
    app.activate()
    XCTAssertTrue(answer(containing: "FIG").waitForExistence(timeout: 60), "the queued message did not run while the app was away")
    XCTAssertFalse(queueRows.firstMatch.exists, "the message is still queued on the phone")
    XCTAssertFalse(onMac.firstMatch.exists, "still shown as waiting on the Mac")
    XCTAssertEqual(userMessage(containing: "FIG").count, 1, "the queued message shows more than once")
    shoot("s3-back-after")

    app.buttons["More"].firstMatch.tap()
    app.buttons["Archive"].firstMatch.tap()
  }

  func testPicturesShow() throws {
    guard let pictureChat, !pictureChat.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_TALARIA_UITEST_PICTURE_CHAT to the title of a chat with pictures.")
    }
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'session.row' AND label CONTAINS %@", pictureChat)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the chat with pictures is not in the inbox")
    row.tap()
    let pictures = app.descendants(matching: .any).matching(identifier: "transcript.picture")
    XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 30), "no picture in the transcript")
    XCTAssertEqual(pictures.count, 2, "expected the attached picture and the delivered one")
    // No raw reference or placeholder is left in the messages, and the reply hides its MEDIA: line.
    let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '@image:' OR label CONTAINS '[screenshot]'"))
    XCTAssertEqual(raw.count, 0, "a picture still shows as its path")
    let media = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'transcript.answer' AND label CONTAINS 'MEDIA:'"))
    XCTAssertEqual(media.count, 0, "the reply still shows its MEDIA: line")
    let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading picture'"))
    XCTAssertTrue(loading.firstMatch.waitForNonExistence(timeout: 30), "a picture never loaded")
    let missing = app.staticTexts.matching(NSPredicate(format: "label == 'No longer on your Mac'"))
    XCTAssertEqual(missing.count, 0, "a picture could not be fetched")
    shoot("p1-pictures")
    // The attached picture sits in the first message, above.
    app.swipeDown()
    app.swipeDown()
    sleep(1)
    shoot("p1b-attached-picture")
    pictures.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["file.share"].waitForExistence(timeout: 30), "the picture did not open full screen")
    sleep(2)
    shoot("p2-picture-open")
    app.buttons["Done"].firstMatch.tap()
  }
}
