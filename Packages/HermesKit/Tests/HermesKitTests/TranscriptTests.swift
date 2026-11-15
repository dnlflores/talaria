import Foundation
import Testing

@testable import HermesKit

@Suite struct TranscriptBuildingTests {
  @Test func historyProjectionBecomesItems() throws {
    let messages = try JSONValue.parse(#"""
      [
        {"role":"user","text":"Fix the flaky test","timestamp":1000},
        {"role":"assistant","text":"Looking.","timestamp":1001,"reasoning":"check CI first"},
        {"role":"tool","name":"patch","context":"tests/a.py","tool_call_id":"call_1","args":{"path":"tests/a.py"},
         "display_metadata":"{\"tool_result_metadata\":{\"inline_diff\":\"+ok\"}}","timestamp":1002},
        {"role":"user","text":"[skill body]","display_kind":"skill_context","timestamp":1003},
        {"role":"user","text":"/review","display_kind":"skill_invocation","timestamp":1004},
        {"role":"assistant","text":"Fixed.","timestamp":1700000000000},
        {"role":"system","text":"ignored"}
      ]
      """#).array ?? []
    let items = TranscriptItem.items(fromHistory: messages)
    #expect(items.map(\.kind) == [.user, .assistant, .tool, .system, .user, .assistant])
    #expect(items[1].reasoning == "check CI first")
    #expect(items[2].tool?.callID == "call_1")
    #expect(items[2].tool?.isDone == true)
    #expect(items[2].tool?.inlineDiff == "+ok")
    #expect(items[5].timestamp == 1_700_000_000)
  }

  @Test func storedRowsJoinCallsWithTheirResults() throws {
    let rows = try JSONValue.parse(#"""
      [
        {"role":"user","content":"[System note: resumed]","timestamp":"1"},
        {"role":"user","content":[{"type":"text","text":"What changed?"},{"type":"image_url","image_url":{}}],"timestamp":"2"},
        {"role":"assistant","content":"raw","display_content":"Let me check.","timestamp":"3",
         "tool_calls":"[{\"id\":\"c1\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{\\\"command\\\":\\\"git log\\\"}\"}},{\"id\":\"c2\",\"function\":{\"name\":\"clarify\",\"arguments\":\"{\\\"question\\\":\\\"Which branch?\\\",\\\"choices\\\":[\\\"main\\\",\\\"dev\\\"]}\"}}]"},
        {"role":"tool","tool_call_id":"c1","content":"abc123 fix","timestamp":"4"},
        {"role":"tool","tool_call_id":"c2","content":"{\"responses\":[{\"question\":\"Which branch?\",\"user_response\":\"dev\",\"status\":\"answered\"}]}","timestamp":"5"},
        {"role":"assistant","content":"","tool_calls":[{"call_id":"c3","name":"web_search","arguments":{"q":"x"}}],"timestamp":"6"}
      ]
      """#).array ?? []
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.map(\.kind) == [.user, .assistant, .tool, .tool, .tool])
    #expect(items[0].text == "What changed?")
    #expect(items[1].text == "Let me check.")
    #expect(items[2].tool?.args["command"].string == "git log")
    #expect(items[2].tool?.isDone == true)
    #expect(items[2].tool?.result == "abc123 fix")
    #expect(items[3].tool?.questions.first?.choices == ["main", "dev"])
    #expect(items[3].tool?.answers?.first?.values == ["dev"])
    #expect(items[4].tool?.name == "web_search")
    #expect(items[4].tool?.isDone == false)
  }

  @Test func signaturesIgnoreWhitespaceAndPreferWhatWasSent() {
    var typed = TranscriptItem(kind: .user, text: "look at this")
    typed.sentText = "look at this\n\n@file:notes.md"
    let stored = TranscriptItem(kind: .user, text: "look at   this @file:notes.md")
    #expect(typed.signature == stored.signature)
    #expect(TranscriptItem(kind: .assistant, text: "a").signature != TranscriptItem(kind: .user, text: "a").signature)
    #expect(TranscriptItem.tool(ToolCall(callID: "1", name: "patch")).signature == TranscriptItem.tool(ToolCall(callID: "2", name: "patch")).signature)
  }
}

@Suite struct TranscriptLayoutTests {
  private func user(_ text: String, at time: Double) -> TranscriptItem { TranscriptItem(kind: .user, text: text, timestamp: time) }
  private func note(_ text: String, at time: Double? = nil) -> TranscriptItem { TranscriptItem(kind: .assistant, text: text, timestamp: time) }
  private func tool(_ name: String, seconds: Double? = nil, done: Bool = true) -> TranscriptItem {
    var call = ToolCall(callID: UUID().uuidString, name: name, isDone: done)
    call.duration = seconds
    return .tool(call)
  }

  private func shape(_ rows: [TranscriptRow]) -> [String] {
    rows.map { row in
      switch row {
      case .user: return "user"
      case .answer: return "answer"
      case .commentary(let item): return "commentary(\(item.text))"
      case .work(let group): return "work(\(group.items.count))"
      case .question: return "question"
      case .edit(let item): return "edit(\(item.tool?.callID ?? ""))"
      case .system: return "system"
      case .files(let turn): return "files(\(turn.files.count))"
      }
    }
  }

  @Test func aFinishedTurnFoldsItsWorkAboveTheAnswer() throws {
    let rows = TranscriptLayout.rows(
      for: [user("go", at: 100), note("I'll look."), tool("terminal", seconds: 2), tool("patch", seconds: 1), note("All fixed.", at: 225)],
      isStreaming: false)
    #expect(shape(rows) == ["user", "commentary(I'll look.)", "work(2)", "answer"])
    guard case .work(let group) = rows[2] else { Issue.record("expected a work group"); return }
    #expect(group.seconds == 125)
    #expect(group.label == "Worked for 2m 5s")
    #expect(group.toolCount == 2)
    #expect(!group.isLive)
  }

  @Test func aRunningTurnKeepsItsLatestActivityLive() {
    let running = TranscriptLayout.rows(for: [user("go", at: 1), note("Checking."), tool("terminal", done: false)], isStreaming: true)
    #expect(shape(running) == ["user", "commentary(Checking.)", "work(1)"])
    guard case .work(let group) = running[2] else { Issue.record("expected a work group"); return }
    #expect(group.isLive)
    #expect(group.label == "1 tool so far")

    // Text being written stays visible as commentary until the final answer is known.
    var streaming = note("The answer is")
    streaming.isStreaming = true
    let answering = TranscriptLayout.rows(for: [user("go", at: 1), tool("terminal"), streaming], isStreaming: true)
    #expect(shape(answering) == ["user", "work(1)", "commentary(The answer is)"])
    let answered = TranscriptLayout.rows(for: [user("go", at: 1), tool("terminal"), note("The answer is 4.")], isStreaming: false)
    #expect(shape(answered) == ["user", "work(1)", "answer"])
  }

  @Test func questionsAndSystemNotesSplitTheWork() {
    let ask = TranscriptItem.tool(ToolCall(callID: "q", name: "clarify", isDone: true))
    let system = TranscriptItem(kind: .system, text: "context compressed")
    let rows = TranscriptLayout.rows(
      for: [user("go", at: 1), tool("terminal"), ask, tool("patch"), system, note("Done.")], isStreaming: false)
    #expect(shape(rows) == ["user", "work(1)", "question", "work(1)", "system", "answer"])
  }

  @Test func emptyAssistantItemsAreNotShownAndEarlierTurnsAreNeverLive() {
    var empty = note("")
    empty.isStreaming = true
    let rows = TranscriptLayout.rows(
      for: [user("one", at: 1), tool("terminal"), note("first"), user("two", at: 5), empty], isStreaming: true)
    #expect(shape(rows) == ["user", "work(1)", "answer", "user"])
    guard case .work(let group) = rows[1] else { Issue.record("expected a work group"); return }
    #expect(!group.isLive)
  }

  @Test func labelsFallBackToToolCounts() {
    #expect(WorkLog(id: UUID(), items: [tool("a"), tool("b")], isLive: false, seconds: nil).label == "2 tools")
    #expect(WorkLog(id: UUID(), items: [tool("a")], isLive: false, seconds: 0.4).label == "1 tool")
    #expect(WorkLog(id: UUID(), items: [tool("a")], isLive: false, seconds: 42).label == "Worked for 42s")
    var thought = TranscriptItem(kind: .assistant)
    thought.reasoning = "weighing options"
    #expect(WorkLog(id: UUID(), items: [thought], isLive: false, seconds: 8).label == "Thought for 8s")
    #expect(WorkLog(id: UUID(), items: [thought], isLive: false, seconds: nil).label == "Thought")
    #expect(WorkLog.duration(59.6) == "1m")
    #expect(WorkLog.duration(725) == "12m")
    #expect(WorkLog.duration(3720) == "1h 2m")
  }
}

@Suite struct SessionModelTests {
  private func row(_ id: String, source: String = "desktop", profile: String = "default", parent: String? = nil,
                   started: Double = 0, active: Double = 0, pinned: Bool = false, title: String = "") -> JSONValue {
    JSONValue.fields([
      "id": .string(id), "source": .string(source), "profile": .string(profile),
      "parent_session_id": parent.map(JSONValue.string), "started_at": .number(started), "last_active": .number(active),
      "pinned": .bool(pinned), "title": .string(title), "runtime_revision": 3, "archived": 0, "unread": 1,
    ])
  }

  @Test func sourcesMapToSections() {
    #expect(SessionSection(source: "desktop") == .chats)
    #expect(SessionSection(source: "") == .chats)
    #expect(SessionSection(source: "Slack") == .platform("slack"))
    #expect(SessionSection(source: "webhook") == .api)
    #expect(SessionSection(source: "cron") == .runs)
    #expect(SessionSection(source: "kanban") == .runs)
    #expect(SessionSection.platform("slack").isChannel)
    #expect(!SessionSection.runs.isChannel)
    #expect(SessionSection.sourceLabel("home_assistant-x") == "Home Assistant X")
  }

  @Test func sidebarSlicesMergeDedupeAndSort() {
    let sidebar: JSONValue = [
      "recents": ["sessions": [row("a", active: 10), row("b", active: 30), row("c", active: 5, pinned: true)]],
      "messaging": ["sessions": [row("b", active: 30), row("s", source: "slack", active: 20)]],
      "cron": ["sessions": [row("k", source: "cron", active: 1)]],
    ]
    let rows = SessionGrouping.rows(fromSidebar: sidebar)
    #expect(rows.map(\.id) == ["c", "b", "s", "a", "k"])
    #expect(rows[0].revision == 3)
    #expect(rows[0].unread)
    #expect(!rows[0].archived)
  }

  @Test func versionsOfOneConversationCollapseToTheNewest() {
    let sessions = [
      row("root", started: 1, active: 10, title: "Plan the trip"),
      row("v2", parent: "root", started: 2, active: 50, title: "Plan the trip #2"),
      row("v3", parent: "v2", started: 3, active: 20, title: "Plan the trip #3"),
      row("other", started: 4, active: 40),
      row("foreign", profile: "scout", parent: "root", started: 5, active: 60),
    ].map(SessionSummary.init(json:))
    let families = SessionGrouping.families(sessions)
    #expect(families["root"]?.members.map(\.id) == ["root", "v2", "v3"])
    #expect(families["v3"]?.preferred.id == "v2")
    #expect(families["other"] == nil)
    #expect(families["foreign"] == nil)

    let collapsed = SessionGrouping.collapse(SessionGrouping.sorted(sessions), families: families)
    #expect(collapsed.map(\.id) == ["foreign", "v2", "other"])
    #expect(sessions[1].baseTitle == "Plan the trip")
  }

  @Test func profilesPreferTheBotTitle() throws {
    let bot = Profile(json: try JSONValue.parse(#"{"name":"scout","display_name":"Scout D","ui_meta":{"hermes-bots":{"title":"Scout"}},"model":"m","has_avatar":true}"#))
    #expect(bot.title == "Scout")
    #expect(bot.hasAvatar)
    #expect(Profile(json: ["name": "default"]).title == "Hermes")
    #expect(Profile(json: ["name": "atlas"]).title == "atlas")
  }

  @Test func modelCatalogOrdersProvidersAndMergesCapabilities() throws {
    let json = try JSONValue.parse(#"""
      {"providers":[
        {"slug":"zeta","name":"Zeta","authenticated":false,"models":["z1"]},
        {"slug":"beta","name":"Beta","authenticated":true,"models":["b1"],"capabilities":{"b1":{"reasoning":true},"b2":{"fast":true}}},
        {"slug":"alpha","name":"Alpha","authenticated":true,"is_current":true,"models":["a1"]}
      ]}
      """#)
    let catalog = ModelProvider.catalog(from: json)
    #expect(catalog.map(\.slug) == ["alpha", "beta", "zeta"])
    #expect(catalog[1].models.map(\.name) == ["b1", "b2"])
    #expect(catalog[1].models[0].supportsReasoning)
    #expect(catalog[1].models[1].supportsFast)
  }
}
