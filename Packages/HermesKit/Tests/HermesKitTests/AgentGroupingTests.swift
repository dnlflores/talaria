import Foundation
import Testing

@testable import HermesKit

@Suite struct AgentGroupingTests {
  private let now: Double = 10_000_000

  private func chat(
    _ id: String, _ profile: String, agoHours: Double, title: String = "", pinned: Bool = false,
    unread: Bool = false, source: String = "desktop", parent: String? = nil
  ) -> SessionSummary {
    var fields: [String: JSONValue] = [
      "id": .string(id), "profile": .string(profile), "title": .string(title.isEmpty ? id : title),
      "source": .string(source), "last_active": .number(now - agoHours * 3600), "started_at": .number(now - agoHours * 3600 - 60),
      "pinned": .bool(pinned), "unread": .bool(unread), "message_count": .number(4),
    ]
    if let parent { fields["parent_session_id"] = .string(parent) }
    return SessionSummary(json: .object(fields))
  }

  @Test func theNewestChatLeadsAndRecentOnesHangUnderIt() {
    let sessions = [
      chat("a1", "default", agoHours: 1), chat("a2", "default", agoHours: 5), chat("a3", "default", agoHours: 20),
      chat("a4", "default", agoHours: 22), chat("a5", "default", agoHours: 30), chat("a6", "default", agoHours: 200),
    ]
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["default"], now: now)
    #expect(groups.count == 1)
    #expect(groups[0].head?.id == "a1")
    // Only three hang under the head; the one past a day and the rest are "more".
    #expect(groups[0].recent.map(\.id) == ["a2", "a3", "a4"])
    #expect(groups[0].moreCount == 2)
  }

  @Test func aPinnedChatLeadsAndItsBotComesFirst() {
    let sessions = [
      chat("p", "default", agoHours: 23, pinned: true), chat("n", "default", agoHours: 1),
      chat("d", "deepseek", agoHours: 0.1),
    ]
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["deepseek", "default"], now: now)
    #expect(groups.map(\.profile) == ["default", "deepseek"])
    #expect(groups[0].head?.id == "p")
    #expect(groups[0].recent.map(\.id) == ["n"])
  }

  @Test func runningAndUnreadChatsShowEvenWhenOld() {
    let sessions = [
      chat("head", "default", agoHours: 2), chat("old-running", "default", agoHours: 90),
      chat("old-unread", "default", agoHours: 400, unread: true), chat("old", "default", agoHours: 50),
    ]
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["default"], isLive: { $0 == "old-running" }, now: now)
    // A running chat comes first under the head.
    #expect(groups[0].recent.map(\.id) == ["old-running", "old-unread"])
    #expect(groups[0].moreCount == 1)
    // And a running chat puts its bot first.
    #expect(groups[0].latest == now)
  }

  @Test func botsAreOrderedByTheirNewestActivityAndEmptyBotsLast() {
    let sessions = [chat("q", "qwen", agoHours: 1_400), chat("h", "harold", agoHours: 1_300), chat("d", "deepseek", agoHours: 3)]
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["scout", "qwen", "harold", "deepseek"], now: now)
    #expect(groups.map(\.profile) == ["deepseek", "harold", "qwen", "scout"])
    #expect(groups.last?.head == nil)
    #expect(groups.last?.moreCount == 0)
  }

  @Test func rowsNotLoadedCountAsMore() {
    let sessions = [chat("r1", "atlas", agoHours: 300), chat("r2", "atlas", agoHours: 400)]
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["atlas"], totals: ["atlas": 20], now: now)
    #expect(groups[0].head?.id == "r1")
    #expect(groups[0].recent.isEmpty)
    #expect(groups[0].moreCount == 1 + 18)
  }

  @Test func versionsOfOneConversationAreOneEntry() {
    let sessions = [chat("root", "default", agoHours: 3), chat("v2", "default", agoHours: 1, parent: "root")]
    let families = SessionGrouping.families(sessions)
    let groups = AgentGrouping.groups(sessions: sessions, profiles: ["default"], families: families, now: now)
    #expect(groups[0].head?.id == "v2")
    #expect(groups[0].recent.isEmpty)
    #expect(groups[0].moreCount == 0)
  }

  @Test func searchFindsBotsByNameAndChatsByTitle() {
    let sessions = [
      chat("a", "scout", agoHours: 1, title: "Groceries"), chat("b", "scout", agoHours: 2, title: "Taxes"),
      chat("c", "default", agoHours: 1, title: "Tax return questions"), chat("d", "default", agoHours: 3, title: "Weather"),
    ]
    let titles = ["scout": "Scout", "default": "Hermes"]
    let byName = AgentGrouping.groups(sessions: sessions, profiles: ["scout", "default"], titles: titles, query: "sco", now: now)
    #expect(byName.map(\.profile) == ["scout"])
    #expect(byName[0].head?.id == "a")

    let byTitle = AgentGrouping.groups(sessions: sessions, profiles: ["scout", "default"], titles: titles, query: "tax", now: now)
    #expect(Set(byTitle.map(\.profile)) == ["scout", "default"])
    #expect(byTitle.first { $0.profile == "scout" }?.head?.id == "b")
    #expect(byTitle.first { $0.profile == "default" }?.head?.id == "c")
    #expect(byTitle.allSatisfy { $0.recent.isEmpty && $0.moreCount == 0 })
  }
}

@Suite struct PreviewTextTests {
  @Test func markdownBecomesOnePlainLine() {
    let text = """
      ## Done

      The **adapter** is built and [verified](https://example.com), but `make` failed once.
      - one
      - two

      ```swift
      let hidden = true
      ```
      MEDIA:/tmp/report.pdf
      """
    #expect(PreviewText.oneLine(text) == "Done The adapter is built and verified, but make failed once. one two")
  }

  @Test func longTextIsCut() {
    let text = String(repeating: "word ", count: 100)
    let line = PreviewText.oneLine(text, limit: 30)
    #expect(line.count == 30)
    #expect(line.hasSuffix("…"))
  }

  @Test func theLastReplyComesFromTheNewestAssistantRow() {
    let rows: [JSONValue] = [
      ["role": "user", "content": "Check the build", "timestamp": 1],
      ["role": "assistant", "content": "**Build** passes.", "timestamp": 2],
      ["role": "assistant", "content": "", "tool_calls": [["id": "t1", "function": ["name": "terminal", "arguments": "{}"]]], "timestamp": 3],
      ["role": "tool", "tool_call_id": "t1", "content": "ok", "timestamp": 4],
    ]
    #expect(PreviewText.lastReply(fromStoredRows: rows) == "Build passes.")
    #expect(PreviewText.lastReply(fromStoredRows: [["role": "user", "content": "hi", "timestamp": 1]]) == nil)
  }
}
