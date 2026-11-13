import Foundation
import Testing

@testable import HermesKit

@Suite struct MemoryNotesTests {
  private func graph() throws -> LearningGraph {
    LearningGraph(json: try JSONValue.parse(Data(#"""
      {"nodes": [
         {"id": "deploy-checks", "label": "deploy-checks", "kind": "skill", "category": "devops", "useCount": 9, "createdBy": "agent"},
         {"id": "memory:memory:0:aaa111", "label": "The staging database is on db-staging", "kind": "memory", "memorySource": "memory", "useCount": 0},
         {"id": "memory:memory:1:bbb222", "label": "Releases go out on Tuesdays", "kind": "memory", "memorySource": "memory", "useCount": 0},
         {"id": "memory:profile:0:ccc333", "label": "Prefers short replies", "kind": "memory", "memorySource": "profile", "useCount": 0}
       ],
       "edges": [{"source": "memory:memory:0:aaa111", "target": "deploy-checks"}],
       "clusters": [], "stats": {},
       "memory": [
         {"source": "memory", "title": "The staging database is on db-staging", "body": "The staging database is on db-staging:5432; run staging migrations with make migrate.", "fingerprint": "aaa111", "timestamp": 1},
         {"source": "memory", "title": "Releases go out on Tuesdays", "body": "Releases go out on Tuesdays after the staging migrations pass.", "fingerprint": "bbb222", "timestamp": 2},
         {"source": "profile", "title": "Prefers short replies", "body": "Prefers short replies without headings.", "fingerprint": "ccc333", "timestamp": 3}
       ]}
      """#.utf8)))
  }

  @Test func notesJoinNodesWithTheirFullText() throws {
    let notes = try graph().memoryNotes
    #expect(notes.map(\.fingerprint) == ["aaa111", "bbb222", "ccc333"])
    #expect(notes[0].text.hasSuffix("make migrate."))
    #expect(notes[0].id == "memory:memory:0:aaa111")
    #expect(!notes[0].isAboutYou)
    #expect(notes[2].isAboutYou)
    #expect(notes[0].titleKey == "aaa111")
  }

  @Test func theWebHoldsOnlyMemories() throws {
    let web = try graph().memoryWeb
    #expect(web.nodes.count == 3)
    #expect(web.nodes.allSatisfy { $0.kind == .memory })
    #expect(web.skills.isEmpty)
    // Both deploy notes talk about staging migrations; the reply preference shares nothing.
    #expect(web.edges == [LearningGraph.Edge(source: "memory:memory:0:aaa111", target: "memory:memory:1:bbb222")])
  }

  @Test func memoriesLinkByWhatTheySay() {
    let notes = [
      MemoryNote(id: "a", text: "Prefers short release notes: what changed and why, plus screenshots."),
      MemoryNote(id: "b", text: "Wants a friendly tone in drafted text: emails, docs, release notes."),
      MemoryNote(id: "c", text: "Reviews code in the morning; wants risky changes pointed out first."),
      MemoryNote(id: "d", text: "The home server backs up photos every night to the NAS."),
      MemoryNote(id: "e", text: "The NAS keeps photos and backups for 90 days."),
      MemoryNote(id: "f", text: "Likes pizza."),
    ]
    let edges = Set(MemoryWeb.links(notes).map { "\($0.source)\($0.target)" })
    #expect(edges.contains("ab"))
    #expect(edges.contains("de"))
    #expect(!edges.contains { $0.contains("f") }, "a note sharing no words links to nothing: \(edges)")
    #expect(!edges.contains("ad") && !edges.contains("be"), "unrelated notes linked: \(edges)")
    // Stable from one load to the next.
    #expect(MemoryWeb.links(notes) == MemoryWeb.links(notes))
    #expect(MemoryWeb.links([notes[0]]).isEmpty)
    #expect(MemoryWeb.links([]).isEmpty)
  }

  @Test func fallbackTitlesComeFromTheFirstClause() {
    #expect(MemoryTitle.fallback("The home dashboard runs at ~/dash (`dash` on PATH; port 8080).") == "The home dashboard runs")
    #expect(MemoryTitle.fallback("Never uses exclamation marks in his own writing; wants them avoided.") == "Never uses exclamation marks")
    #expect(MemoryTitle.fallback("npm install works now (/usr/local owned by the user).") == "Npm install works now")
    #expect(MemoryTitle.fallback("# Release days\nReleases go out on Tuesdays.") == "Release days")
    #expect(MemoryTitle.fallback("iOS builds sign automatically") == "iOS builds sign automatically")
    #expect(MemoryTitle.fallback("") == "Memory")
  }

  @Test func modelTitlesAreCleanedUp() {
    #expect(MemoryTitle.clean("\"Home dashboard.\"") == "Home dashboard")
    #expect(MemoryTitle.clean("Label: release note style\nextra") == "Release note style")
    #expect(MemoryTitle.clean("PR review habits") == "PR review habits")
    #expect(MemoryTitle.clean("iOS build setup") == "iOS build setup")
    #expect(MemoryTitle.clean("one two three four five six seven") == "One two three four five six")
    #expect(MemoryTitle.clean("a b c d e f g h i j") == nil)
    #expect(MemoryTitle.clean("   ") == nil)
  }
}
