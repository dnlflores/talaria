import Foundation
import Testing
@testable import HermesKit

@Suite struct QueueOriginTests {
  @Test func talariaWritesItsDeviceIntoTheSubmissionID() {
    let id = QueueOrigin.submissionID(device: "iPhone")
    #expect(id.hasPrefix("talaria.iphone."))
    #expect(QueueOrigin(inputID: id) == .talaria(device: "iPhone"))
    #expect(QueueOrigin(inputID: QueueOrigin.submissionID(device: "iPad")).label == "iPad")
  }

  @Test func otherAppsAreToldApartByTheirIDShape() {
    // The desktop app sends a UUID, the terminal a bare 32-digit hex id.
    #expect(QueueOrigin(inputID: "6bb42be0-e157-4948-9c0e-0c23853f244d") == .desktop)
    #expect(QueueOrigin(inputID: "6bb42be0e15749489c0e0c23853f244d") == .terminal)
    #expect(QueueOrigin(inputID: "cron:job:1") == .unknown)
    #expect(QueueOrigin(inputID: "talaria.") == .unknown)
    #expect(QueueOrigin.desktop.label == "Hermes desktop")
  }

  @Test func aRenewedIDKeepsItsDevice() {
    let first = QueueOrigin.submissionID(device: "iPad")
    let renewed = QueueOrigin.renewed(first)
    #expect(renewed != first)
    #expect(QueueOrigin(inputID: renewed) == .talaria(device: "iPad"))
  }

  @Test func theQueueTagsWhatItEnqueuesAndKeepsTheTagThroughCancellation() {
    var queue = PromptQueue<Int>(device: "iPhone")
    let entry = queue.enqueue(text: "later", now: 1)
    #expect(QueueOrigin(inputID: entry.submissionID) == .talaria(device: "iPhone"))
    queue.moveToMac(entry.id)
    queue.returnFromMac([queue.removeOnMac(entry.id)!])
    let returned = queue.entries[0]
    #expect(returned.submissionID != entry.submissionID)
    #expect(QueueOrigin(inputID: returned.submissionID) == .talaria(device: "iPhone"))
  }

  @Test func takingOneBackFromTheMacDoesNotHoldTheQueue() {
    var queue = PromptQueue<Int>(device: "iPhone")
    let handed = queue.enqueue(text: "handed over", attachments: [7], now: 1)
    queue.moveToMac(handed.id)
    let local = queue.enqueue(text: "still here", now: 2)
    let back = queue.takeBackFromMac(handed.id)
    #expect(back?.attachments == [7])
    #expect(back?.submissionID != handed.submissionID)
    #expect(queue.onMac.isEmpty)
    #expect(queue.entries.map(\.id) == [handed.id, local.id])
    #expect(!queue.isPaused)
    #expect(queue.takeBackFromMac(handed.id) == nil)
  }

  @Test func theMacsQueueListIsReadFromPending() {
    let pending: JSONValue = [
      ["admission_id": "a1", "input_id": "talaria.ipad.x", "text": "from the iPad", "status": "queued",
       "controls": ["steer", "replace"]],
      ["admission_id": "a2", "input_id": "6bb42be0-e157-4948-9c0e-0c23853f244d", "text": "", "status": "queued"],
      ["admission_id": "a3", "input_id": "u", "text": "steering", "status": "started", "steering": true],
    ]
    let rows = QueuedOnMac.list(pending)!
    #expect(rows.map(\.origin) == [.talaria(device: "iPad"), .desktop, .unknown])
    #expect(rows[0].canSteer && rows[0].isWaiting)
    #expect(!rows[1].canSteer)
    #expect(!rows[2].isWaiting)
    #expect(QueuedOnMac.list(.null) == nil)
    let live = LiveSession(json: ["session_id": "s", "pending": pending])
    #expect(live.pending?.count == 3)
    #expect(LiveSession(json: ["session_id": "s"]).pending == nil)
  }
}
