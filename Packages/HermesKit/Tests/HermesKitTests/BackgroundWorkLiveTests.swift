import Foundation
import Testing
@testable import HermesKit

@Suite struct BackgroundWorkLiveTests {
  @Test(.enabled(if: Live.base != nil && Live.environment["TALARIA_BACKGROUND_SESSION"] != nil))
  func readsScopedBackgroundWorkWithoutResumingTheChat() async throws {
    let sessionID = try #require(Live.environment["TALARIA_BACKGROUND_SESSION"])
    let client = try Live.client()
    await client.rpc.start()
    do {
      try await client.rpc.waitUntilReady(timeout: 20)
      let snapshot = try await client.backgroundWork(profile: Live.profile, storedID: sessionID)
      #expect(!snapshot.rows.isEmpty, "name a chat with known background work for this opt-in check")
      for row in snapshot.rows {
        #expect(row.id.hasPrefix(row.kind == .agent ? "agent:" : "process:") || row.id.hasPrefix("delegation:"))
        #expect(!row.title.isEmpty)
      }
      print("LIVE background rows: \(snapshot.rows.count), running: \(snapshot.rows.filter { $0.status.isRunning }.count)")
      await client.rpc.stop()
    } catch {
      await client.rpc.stop()
      throw error
    }
  }
}
