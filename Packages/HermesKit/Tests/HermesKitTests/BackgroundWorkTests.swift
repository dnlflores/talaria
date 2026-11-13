import Testing
@testable import HermesKit

private actor BackgroundRequestRecorder {
  var requests: [(String, JSONValue)] = []
  func record(_ method: String, _ params: JSONValue) { requests.append((method, params)) }
}

@Suite struct BackgroundWorkTests {
  @Test func firstNetworkFailureDoesNotInventASuccessfulLastCheck() {
    var state = BackgroundWorkState()
    state.markUnavailable()
    #expect(state.isUnavailable)
    #expect(!state.hasSnapshot)
  }

  @Test func onlyTheRequestedProfileAndStoredSessionAreRead() async throws {
    let recorder = BackgroundRequestRecorder()
    _ = try await BackgroundWorkSnapshot.load(scope: BackgroundWorkScope(profile: "example-profile", storedID: "local-example")) { method, params in
      await recorder.record(method, params)
      return method == "subagent.list" ? ["subagents": []] : ["processes": []]
    }
    let requests = await recorder.requests
    #expect(Set(requests.map(\.0)) == ["subagent.list", "process.list"])
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.1 == ["session_id": "local-example", "profile": "example-profile"] })
  }

  @Test func missingScopeCannotFallBackToAllSessions() async {
    await #expect(throws: BackgroundWorkError.self) {
      _ = try await BackgroundWorkSnapshot.load(scope: BackgroundWorkScope(profile: "", storedID: "")) { _, _ in
        Issue.record("Unscoped RPC must not be called")
        return [:]
      }
    }
  }

  @Test func disappearanceIsNotInventedSuccessAndNetworkErrorsKeepLastKnownWork() throws {
    var state = BackgroundWorkState()
    let active = try BackgroundWorkSnapshot(subagents: ["subagents": [["subagent_id": "a", "status": "running"]]], processes: ["processes": []])
    state.apply(active)
    state.markUnavailable()
    #expect(state.isUnavailable)
    #expect(state.runningCount == 1)
    #expect(state.rows.first?.status == .running)
    state.apply(try BackgroundWorkSnapshot(subagents: ["subagents": []], processes: ["processes": []]))
    #expect(!state.isUnavailable)
    #expect(state.runningCount == 0)
    #expect(state.rows.first?.status == .finished)
    state.apply(active)
    #expect(state.runningCount == 1)
    #expect(state.rows.count == 1)
  }

  @Test func historyIsBoundedWithoutDroppingActiveWork() throws {
    var state = BackgroundWorkState()
    let commands: [JSONValue] = (0..<80).map { index in
      ["session_id": .string("p-\(index)"), "status": .string(index < 30 ? "running" : "exited"), "exit_code": 0, "started_epoch": .number(Double(index))]
    }
    state.apply(try BackgroundWorkSnapshot(subagents: ["subagents": []], processes: ["processes": .array(commands)]))
    #expect(state.runningCount == 30)
    #expect(state.rows.count == 50)
    #expect(state.rows.filter { !$0.status.isRunning }.count == 20)
    #expect(state.rows.last?.startedAt == 60)
  }

  @Test func malformedReadsMustNotLookLikeAnEmptySuccessfulPoll() {
    #expect(throws: BackgroundWorkError.self) {
      try BackgroundWorkSnapshot(subagents: [:], processes: ["processes": []])
    }
  }

  @Test func authoritativeStatusesDistinguishSuccessFailureAndStop() throws {
    let snapshot = try BackgroundWorkSnapshot(subagents: ["subagents": [
      ["subagent_id": "a", "status": "completed"],
      ["subagent_id": "b", "status": "timeout"],
      ["subagent_id": "c", "status": "interrupted"],
      ["subagent_id": "d", "status": "queued"],
      ["subagent_id": "e", "status": "new-status"],
    ], "delegations": [["delegation_id": "failed-task", "task_index": 2, "status": "failed", "goal": "Check another file", "error": "Runner unavailable"]]], processes: ["processes": [
      ["session_id": "ok", "status": "exited", "exit_code": 0],
      ["session_id": "bad", "status": "exited", "exit_code": 1],
      ["session_id": "stop", "status": "exited", "exit_code": 0, "completion_reason": "killed"],
      ["session_id": "lost", "status": "exited", "completion_reason": "lost"],
    ]])
    let statuses = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0.status) })
    #expect(statuses["agent:a"] == .completed)
    #expect(statuses["agent:b"] == .failed)
    #expect(statuses["agent:c"] == .stopped)
    #expect(statuses["agent:d"] == .queued)
    #expect(statuses["agent:e"] == .unknown)
    #expect(statuses["delegation:failed-task:2"] == .failed)
    #expect(statuses["process:ok"] == .completed)
    #expect(statuses["process:bad"] == .failed)
    #expect(statuses["process:stop"] == .stopped)
    #expect(statuses["process:lost"] == .unknown)
  }

  @Test func runningWorkDoesNotDependOnTheMainTurn() throws {
    let snapshot = try BackgroundWorkSnapshot(subagents: ["subagents": [[
      "subagent_id": "child-1", "goal": "Check the build while the chat is idle", "status": "running", "started_at": 100,
    ]]], processes: ["processes": [[
      "session_id": "process-1", "command": "swift test", "status": "running", "started_epoch": 101,
    ]]])
    var state = BackgroundWorkState()
    state.apply(snapshot)
    #expect(state.runningCount == 2)
    #expect(state.summary == "Background work · 2 running")
    #expect(state.rows.map(\.title).contains("Check the build while the chat is idle"))
    #expect(state.rows.first(where: { $0.kind == .process })?.title == "Background command")
    #expect(state.rows.first(where: { $0.kind == .process })?.detail == "swift test")
  }
}
