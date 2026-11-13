import Foundation

/// What Hermes has learned for a bot (`GET /api/learning/graph?profile=`): the skills it made or
/// uses and its memory notes as nodes, linked by declared `related_skills` and by the skills a
/// note mentions. The desktop app draws the same graph as its star map.
public struct LearningGraph: Sendable, Equatable {
  public struct Node: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case skill, memory }
    public let id: String
    public let label: String
    public let kind: Kind
    /// `memory` (notes) or `profile` (about the person), for memory nodes.
    public let memorySource: String
    public let category: String
    public let useCount: Int
    public let state: String
    /// `agent` or `learn` for skills Hermes wrote, `installed` for ones that came from a hub.
    public let createdBy: String
    public let pinned: Bool
    public let timestamp: Double?

    public init(json: JSONValue) {
      id = json["id"].stringValue
      label = json["label"].string ?? id
      kind = Kind(rawValue: json["kind"].stringValue) ?? .skill
      memorySource = json["memorySource"].stringValue
      category = json["category"].stringValue
      useCount = json["useCount"].int ?? 0
      state = json["state"].stringValue
      createdBy = json["createdBy"].stringValue
      pinned = json["pinned"].truthy
      timestamp = json["timestamp"].double
    }

    public init(id: String, label: String, kind: Kind, category: String = "", useCount: Int = 0) {
      self.id = id
      self.label = label
      self.kind = kind
      memorySource = kind == .memory ? "memory" : ""
      self.category = category
      self.useCount = useCount
      state = "active"
      createdBy = ""
      pinned = false
      timestamp = nil
    }

    /// Made by Hermes itself rather than installed.
    public var isLearned: Bool { createdBy == "agent" || createdBy == "learn" }
  }

  public struct Edge: Sendable, Equatable, Hashable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
      self.source = source
      self.target = target
    }
  }

  /// A memory note as a card: its text, and whether it is about the work or the person.
  public struct MemoryCard: Identifiable, Sendable, Equatable {
    public var id: String { fingerprint.isEmpty ? "\(source):\(title)" : fingerprint }
    public let source: String
    public let title: String
    public let body: String
    public let fingerprint: String
    public let timestamp: Double?

    public init(json: JSONValue) {
      source = json["source"].stringValue
      title = json["title"].stringValue
      body = json["body"].stringValue
      fingerprint = json["fingerprint"].stringValue
      timestamp = json["timestamp"].double
    }

    public var isAboutYou: Bool { source == "profile" }
  }

  public let nodes: [Node]
  public let edges: [Edge]
  public let memory: [MemoryCard]

  public init(json: JSONValue) {
    let nodes = (json["nodes"].array ?? []).map(Node.init(json:)).filter { !$0.id.isEmpty }
    let ids = Set(nodes.map(\.id))
    var seen = Set<Edge>()
    edges = (json["edges"].array ?? []).compactMap { edge -> Edge? in
      let source = edge["source"].stringValue
      let target = edge["target"].stringValue
      guard source != target, ids.contains(source), ids.contains(target) else { return nil }
      // One line per pair, whichever way round it was declared.
      let pair = source < target ? Edge(source: source, target: target) : Edge(source: target, target: source)
      return seen.insert(pair).inserted ? pair : nil
    }
    self.nodes = nodes
    memory = (json["memory"].array ?? []).map(MemoryCard.init(json:))
  }

  public init(nodes: [Node], edges: [Edge], memory: [MemoryCard] = []) {
    self.nodes = nodes
    self.edges = edges
    self.memory = memory
  }

  public var skills: [Node] { nodes.filter { $0.kind == .skill } }

  /// Skills most used first, then by name.
  public var skillsByUse: [Node] {
    skills.sorted { a, b in
      if a.useCount != b.useCount { return a.useCount > b.useCount }
      return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }
  }

  /// The ids of the nodes linked to one node.
  public func neighbours(of id: String) -> Set<String> {
    var found = Set<String>()
    for edge in edges {
      if edge.source == id { found.insert(edge.target) }
      if edge.target == id { found.insert(edge.source) }
    }
    return found
  }

  /// "software-development" reads as "Software development".
  public static func categoryTitle(_ category: String) -> String {
    SkillCategory(name: category, skills: []).title
  }
}

/// Places the graph's nodes for drawing: linked nodes pull together, every pair pushes apart, and
/// the whole stays round. Deterministic (the same graph lands the same way every time), so the map
/// does not reshuffle on each visit.
public enum ConstellationLayout {
  public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  /// Positions by node id, centered on the origin. `spacing` is about the distance between two
  /// linked nodes.
  public static func positions(for graph: LearningGraph, spacing: Double = 150, iterations: Int = 400) -> [String: Point] {
    let nodes = graph.nodes
    let count = nodes.count
    guard count > 0 else { return [:] }
    guard count > 1 else { return [nodes[0].id: Point(x: 0, y: 0)] }

    // Most used first, so the busiest skills start (and usually stay) near the middle.
    let order = nodes.indices.sorted { a, b in
      let (na, nb) = (nodes[a], nodes[b])
      if (na.kind == .skill) != (nb.kind == .skill) { return na.kind == .skill }
      if na.useCount != nb.useCount { return na.useCount > nb.useCount }
      return na.id < nb.id
    }
    var x = [Double](repeating: 0, count: count)
    var y = [Double](repeating: 0, count: count)
    let golden = Double.pi * (3 - 5.0.squareRoot())
    for (rank, index) in order.enumerated() {
      let radius = spacing * 0.6 * Double(rank).squareRoot()
      x[index] = radius * cos(Double(rank) * golden)
      y[index] = radius * sin(Double(rank) * golden)
    }

    let position = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    let links = graph.edges.compactMap { edge -> (Int, Int)? in
      guard let a = position[edge.source], let b = position[edge.target] else { return nil }
      return (a, b)
    }
    let weight = nodes.map { $0.kind == .memory ? 0.6 : 1.0 }
    // Gravity sized so the pushing apart settles into a disc about this wide: every node gets
    // room for its name, and the map stays a web rather than scattering to the edges.
    let radius = spacing * 0.45 * Double(count).squareRoot()
    let gravity = Double(count) * spacing * spacing / (radius * radius)

    var temperature = spacing
    for _ in 0..<max(iterations, 1) {
      var dx = [Double](repeating: 0, count: count)
      var dy = [Double](repeating: 0, count: count)
      // Every pair pushes apart, harder up close.
      for i in 0..<count {
        for j in (i + 1)..<count {
          var ddx = x[i] - x[j]
          var ddy = y[i] - y[j]
          var distance2 = ddx * ddx + ddy * ddy
          if distance2 < 0.01 {
            // Two nodes on one spot: nudge them apart the same way every run.
            ddx = Double((i * 7 + j * 13) % 11) - 5
            ddy = Double((i * 3 + j * 5) % 7) - 3
            distance2 = ddx * ddx + ddy * ddy + 0.01
          }
          let distance = distance2.squareRoot()
          let force = spacing * spacing * weight[i] * weight[j] / distance
          dx[i] += ddx / distance * force
          dy[i] += ddy / distance * force
          dx[j] -= ddx / distance * force
          dy[j] -= ddy / distance * force
        }
      }
      // Links pull together.
      for (a, b) in links {
        let ddx = x[a] - x[b]
        let ddy = y[a] - y[b]
        let distance = max((ddx * ddx + ddy * ddy).squareRoot(), 0.01)
        let force = distance * distance / spacing
        dx[a] -= ddx / distance * force
        dy[a] -= ddy / distance * force
        dx[b] += ddx / distance * force
        dy[b] += ddy / distance * force
      }
      // Gravity keeps loose nodes from drifting off.
      for i in 0..<count {
        let r = max((x[i] * x[i] + y[i] * y[i]).squareRoot(), 0.01)
        dx[i] -= x[i] / r * gravity * r * r / radius
        dy[i] -= y[i] / r * gravity * r * r / radius
        let length = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 0.01)
        let step = min(length, temperature)
        x[i] += dx[i] / length * step
        y[i] += dy[i] / length * step
      }
      temperature = max(temperature * 0.985, spacing * 0.01)
    }

    // Last, make room for the names: a skill's label hangs under its disc, about 128 wide and
    // 70 tall with the disc, so two skills that close are pushed apart along the shorter overlap.
    let isSkill = nodes.map { $0.kind == .skill }
    for _ in 0..<120 {
      var moved = false
      for i in 0..<count {
        for j in (i + 1)..<count {
          let (boxX, boxY): (Double, Double) = isSkill[i] && isSkill[j] ? (134, 78) : (isSkill[i] || isSkill[j] ? (80, 56) : (34, 34))
          let ddx = x[j] - x[i]
          let ddy = y[j] - y[i]
          let overlapX = boxX - abs(ddx)
          let overlapY = boxY - abs(ddy)
          guard overlapX > 0, overlapY > 0 else { continue }
          moved = true
          if overlapX / boxX < overlapY / boxY {
            let push = overlapX / 2 * (ddx >= 0 ? 1 : -1)
            x[i] -= push
            x[j] += push
          } else {
            let push = overlapY / 2 * (ddy >= 0 ? 1 : -1)
            y[i] -= push
            y[j] += push
          }
        }
      }
      if !moved { break }
    }

    let meanX = x.reduce(0, +) / Double(count)
    let meanY = y.reduce(0, +) / Double(count)
    var result: [String: Point] = [:]
    for (index, node) in nodes.enumerated() {
      result[node.id] = Point(x: x[index] - meanX, y: y[index] - meanY)
    }
    return result
  }
}

extension HermesClient {
  /// What Hermes has learned for a bot: skills and memory notes as a graph.
  public func learningGraph(profile: String) async throws -> LearningGraph {
    LearningGraph(json: try await http.json("GET", "/api/learning/graph", query: [("profile", profile)], timeout: 45))
  }

  /// A skill's SKILL.md or a memory note's text, by graph node id.
  public func learningNode(id: String, profile: String) async throws -> String {
    let json = try await http.json("GET", "/api/learning/node", query: [("id", id), ("profile", profile)], timeout: 30)
    return json["content"].stringValue
  }
}
