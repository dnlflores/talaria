import Foundation
import Testing

@testable import HermesKit

@Suite struct BrandAndLearningTests {
  @Test func modelsShowTheirMakersLogo() {
    #expect(ModelBrand.logo(model: "gpt-6.1-sol-900k", provider: "openai-codex") == "openai")
    #expect(ModelBrand.logo(model: "gpt-oss-120b-medium", provider: "nous") == "openai")
    #expect(ModelBrand.logo(model: "claude-opus-5-5", provider: "anthropic") == "claude")
    #expect(ModelBrand.logo(model: "anthropic/claude-sonnet-5", provider: "nous") == "claude")
    #expect(ModelBrand.logo(model: "google/gemini-3.8-flash", provider: "nous") == "gemini")
    #expect(ModelBrand.logo(model: "gemma-4-27b", provider: "nous") == "gemma")
    #expect(ModelBrand.logo(model: "x-ai/grok-4.7", provider: "nous") == "grok")
    #expect(ModelBrand.logo(model: "deepseek/deepseek-v4.1-flash", provider: "nous") == "deepseek")
    #expect(ModelBrand.logo(model: "moonshotai/kimi-k3", provider: "nous") == "kimi")
    #expect(ModelBrand.logo(model: "z-ai/glm-5", provider: "nous") == "zai")
    #expect(ModelBrand.logo(model: "nousresearch/hermes-5-405b", provider: "nous") == "nousresearch")
    #expect(ModelBrand.logo(model: "Qwen3.6-35B-A3B-UD-Q4_K_M", provider: "llamacpp") == "qwen")
    // A vendor prefix decides when the name says nothing.
    #expect(ModelBrand.logo(model: "mistralai/some-new-model", provider: "openrouter") == "mistral")
    // Nothing known about the model: the provider's logo, or none.
    #expect(ModelBrand.logo(model: "mystery-1", provider: "openrouter") == "openrouter")
    #expect(ModelBrand.logo(model: "mystery-1", provider: "llamacpp") == nil)
    #expect(ModelBrand.logo(model: "", provider: "") == nil)
  }

  @Test func providersShowTheirOwnLogo() {
    #expect(ModelBrand.logo(provider: "nous") == "nousresearch")
    #expect(ModelBrand.logo(provider: "anthropic") == "anthropic")
    #expect(ModelBrand.logo(provider: "openai-codex") == "openai")
    #expect(ModelBrand.logo(provider: "antigravity-agy") == "antigravity")
    #expect(ModelBrand.logo(provider: "xai-grok-oauth") == "xai")
    #expect(ModelBrand.logo(provider: "github-copilot") == "githubcopilot")
    #expect(ModelBrand.logo(provider: "llamacpp") == nil)
    #expect(ModelBrand.isLocal(provider: "llamacpp"))
    #expect(!ModelBrand.isLocal(provider: "anthropic"))
  }

  private func graphJSON() throws -> JSONValue {
    try JSONValue.parse(Data(#"""
      {"nodes": [
         {"id": "alpha", "label": "alpha", "kind": "skill", "category": "software-development", "useCount": 40, "state": "active", "createdBy": "agent", "pinned": false, "timestamp": 1790000000},
         {"id": "beta", "label": "beta", "kind": "skill", "category": "productivity", "useCount": 7, "state": "active", "createdBy": "installed", "pinned": false},
         {"id": "gamma", "label": "gamma", "kind": "skill", "category": "productivity", "useCount": 7, "state": "stale", "createdBy": "learn", "pinned": true},
         {"id": "memory:memory:0:abc", "label": "A note", "kind": "memory", "memorySource": "memory", "category": "memory", "useCount": 0, "createdBy": "memory"}
       ],
       "edges": [
         {"source": "alpha", "target": "beta"}, {"source": "beta", "target": "alpha"},
         {"source": "memory:memory:0:abc", "target": "gamma"}, {"source": "alpha", "target": "missing"},
         {"source": "alpha", "target": "alpha"}
       ],
       "clusters": [], "stats": {},
       "memory": [{"source": "profile", "timestamp": 1790000001, "title": "Likes short replies", "body": "Likes short replies", "fingerprint": "f00"}]}
      """#.utf8))
  }

  @Test func learningGraphDecodes() throws {
    let graph = LearningGraph(json: try graphJSON())
    #expect(graph.nodes.count == 4)
    #expect(graph.skills.count == 3)
    // Duplicates, self links and links to missing nodes are dropped.
    #expect(graph.edges.count == 2)
    #expect(graph.neighbours(of: "alpha") == ["beta"])
    #expect(graph.neighbours(of: "gamma") == ["memory:memory:0:abc"])
    #expect(graph.skillsByUse.map(\.id) == ["alpha", "beta", "gamma"])
    #expect(graph.nodes[0].isLearned)
    #expect(!graph.nodes[1].isLearned)
    #expect(graph.nodes[2].pinned)
    #expect(graph.nodes[3].kind == .memory)
    #expect(graph.memory.first?.isAboutYou == true)
    #expect(graph.memory.first?.id == "f00")
    #expect(LearningGraph.categoryTitle("software-development") == "Software development")
  }

  @Test func layoutIsStableSpreadAndKeepsLinksClose() {
    var nodes: [LearningGraph.Node] = []
    var edges: [LearningGraph.Edge] = []
    for index in 0..<40 {
      nodes.append(.init(id: "s\(index)", label: "skill-\(index)", kind: index % 5 == 4 ? .memory : .skill, useCount: 40 - index))
    }
    // Rings of four linked skills.
    for ring in 0..<10 {
      for step in 0..<3 { edges.append(.init(source: "s\(ring * 4 + step)", target: "s\(ring * 4 + step + 1)")) }
    }
    let graph = LearningGraph(nodes: nodes, edges: edges)
    let first = ConstellationLayout.positions(for: graph, spacing: 150)
    let second = ConstellationLayout.positions(for: graph, spacing: 150)
    #expect(first == second)
    #expect(first.count == 40)
    #expect(first.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })

    func distance(_ a: String, _ b: String) -> Double {
      let (p, q) = (first[a]!, first[b]!)
      return ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
    }
    let ids = nodes.map(\.id)
    var closest = Double.infinity
    var unlinked: [Double] = []
    let linked = Set(edges.map { "\($0.source)|\($0.target)" })
    for i in 0..<ids.count {
      for j in (i + 1)..<ids.count {
        let d = distance(ids[i], ids[j])
        closest = min(closest, d)
        if !linked.contains("\(ids[i])|\(ids[j])") { unlinked.append(d) }
      }
    }
    let linkedMean = edges.map { distance($0.source, $0.target) }.reduce(0, +) / Double(edges.count)
    let unlinkedMean = unlinked.reduce(0, +) / Double(unlinked.count)
    // No two nodes on top of each other, and linked ones sit nearer than the rest.
    #expect(closest > 40, "closest pair \(closest)")
    #expect(linkedMean < unlinkedMean * 0.6, "linked \(linkedMean) vs unlinked \(unlinkedMean)")
    #expect(ConstellationLayout.positions(for: LearningGraph(nodes: [], edges: [])).isEmpty)
  }
}
