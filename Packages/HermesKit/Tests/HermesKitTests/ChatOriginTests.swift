import Foundation
import Testing
@testable import HermesKit

struct ChatOriginTests {
  private func row(_ id: String, source: String, created: String? = nil, parent: String? = nil) -> SessionSummary {
    var fields: [String: JSONValue] = ["id": .string(id), "source": .string(source), "profile": "default"]
    if let created { fields["created_source"] = .string(created) }
    if let parent { fields["parent_session_id"] = .string(parent) }
    return SessionSummary(json: .object(fields))
  }

  @Test func readsTheMacsFile() {
    let map = ChatOriginMap(json: """
      {"generated_at":"2026-11-13T21:24:20-05:00","rules_version":1,"chats":{
        "a":"talaria||l","b":"automation|cron|c","c":"slack||c","d":"desktop||g","e":"rocket||c"}}
      """)
    #expect(map.generatedAt == "2026-11-13T21:24:20-05:00")
    #expect(map.tags["a"] == ChatOriginTag(origin: .talaria, confidence: .likely))
    #expect(map.tags["b"] == ChatOriginTag(origin: .automation, detail: "cron", confidence: .certain))
    #expect(map.tags["c"] == ChatOriginTag(origin: .messaging, detail: "slack", confidence: .certain))
    #expect(map.tags["d"]?.confidence == .guess)
    #expect(map.tags["e"] == nil)  // an origin from a newer script falls back to the row
    #expect(ChatOriginMap(json: "{\"chats\": {\"a\": \"tal").tags.isEmpty)  // cut short
  }

  @Test func phoneThenBackfillThenSource() {
    let map = ChatOriginMap(tags: ["x": ChatOriginTag(origin: .desktop, confidence: .guess)], generatedAt: "")
    #expect(map.tag(for: row("x", source: "gui"), startedHere: ["x"]).origin == .talaria)
    #expect(map.tag(for: row("x", source: "gui")).origin == .desktop)
    #expect(map.tag(for: row("x2", source: "gui", parent: "x")).origin == .desktop)
    #expect(map.tag(for: row("new", source: "gui")).origin == .unknown)
    #expect(map.tag(for: row("s", source: "slack")).origin == .messaging)
    #expect(map.tag(for: row("k", source: "kanban")).detail == "kanban")
    #expect(map.tag(for: row("t", source: "tui")).origin == .terminal)
    #expect(map.tag(for: row("w", source: "local", created: "cli")).origin == .workdash)
  }

  @Test func filters() {
    #expect(ChatOriginFilter(storage: "") == .all)
    #expect(ChatOriginFilter(storage: "personal") == .personal)
    #expect(ChatOriginFilter(storage: "talaria") == .only(.talaria))
    #expect(ChatOriginFilter(storage: "nonsense") == .all)
    #expect(ChatOriginFilter.personal.includes(.talaria))
    #expect(ChatOriginFilter.personal.includes(.unknown))
    #expect(!ChatOriginFilter.personal.includes(.workdash))
    #expect(!ChatOriginFilter.only(.desktop).includes(.talaria))
    for filter in ChatOriginFilter.menu { #expect(ChatOriginFilter(storage: filter.storage) == filter) }
  }
}
