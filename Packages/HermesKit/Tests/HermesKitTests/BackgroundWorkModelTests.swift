import Testing
@testable import HermesKit

private actor BackgroundWorkGate {
  var started = false
  var pending: CheckedContinuation<BackgroundWorkSnapshot, Never>?
  func fetch() async -> BackgroundWorkSnapshot {
    started = true
    return await withCheckedContinuation { pending = $0 }
  }
  func release(_ snapshot: BackgroundWorkSnapshot) { pending?.resume(returning: snapshot); pending = nil }
}

@Suite @MainActor struct BackgroundWorkModelTests {
  private var scope: BackgroundWorkScope { .init(profile: "test", storedID: "local-test") }
  private func running() throws -> BackgroundWorkSnapshot {
    try .init(subagents: ["subagents": [["subagent_id": "a", "status": "running"]]], processes: ["processes": []])
  }

  @Test func leavingOrBackgroundingRejectsALatePoll() async throws {
    let model = BackgroundWorkModel()
    let gate = BackgroundWorkGate()
    let task = Task { await model.run(scope: scope, fetch: { await gate.fetch() }) }
    while !(await gate.started) { await Task.yield() }
    model.pause()
    task.cancel()
    await gate.release(try running())
    await task.value
    #expect(model.state.rows.isEmpty)
    #expect(!model.hasChecked)
    #expect(model.isPaused)
  }

  @Test func returningToForegroundPollsImmediatelyAndChangingChatClearsOldRows() async throws {
    let model = BackgroundWorkModel()
    let snapshot = try running()
    await model.run(scope: scope, fetch: { snapshot }, wait: { throw CancellationError() })
    #expect(model.state.runningCount == 1)
    model.pause()
    await model.run(scope: .init(profile: "other", storedID: "local-other"), fetch: { throw BackgroundWorkError.invalidResponse }, wait: { throw CancellationError() })
    #expect(model.state.rows.isEmpty)
    #expect(model.state.isUnavailable)
    await model.run(scope: scope, fetch: { snapshot }, wait: { throw CancellationError() })
    #expect(model.state.runningCount == 1)
    #expect(!model.state.isUnavailable)
    #expect(model.hasChecked)
  }
}
