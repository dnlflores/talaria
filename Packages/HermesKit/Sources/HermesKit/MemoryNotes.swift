import Foundation

/// One memory a bot keeps (an entry of its MEMORY.md, or of USER.md when it is about the person),
/// joined from the learning graph's node (its id opens it) and card (its full text).
public struct MemoryNote: Identifiable, Sendable, Equatable {
  /// The graph node id, `memory:<source>:<index>:<fingerprint>`; `/api/learning/node` opens it.
  public let id: String
  /// Digest of the text: the same memory has the same one on every device and after a reload.
  public let fingerprint: String
  /// From USER.md: about the person rather than the work.
  public let isAboutYou: Bool
  public let text: String
  public let timestamp: Double?

  public init(id: String, fingerprint: String = "", isAboutYou: Bool = false, text: String, timestamp: Double? = nil) {
    self.id = id
    self.fingerprint = fingerprint
    self.isAboutYou = isAboutYou
    self.text = text
    self.timestamp = timestamp
  }

  /// Its title: its own opening words (`MemoryTitle.make`).
  public var title: String { MemoryTitle.make(text) }

  /// The file Hermes keeps it in.
  public var fileName: String { isAboutYou ? "USER.md" : "MEMORY.md" }
}

extension LearningGraph {
  /// The bot's memories in the order Hermes keeps them (MEMORY.md, then USER.md).
  public var memoryNotes: [MemoryNote] {
    let nodes = self.nodes.filter { $0.kind == .memory }
    return nodes.enumerated().map { offset, node in
      // A node id ends with its card's fingerprint; an older backend without fingerprints lists
      // nodes and cards in the same order.
      let card = memory.first { !$0.fingerprint.isEmpty && node.id.hasSuffix(":\($0.fingerprint)") }
        ?? (memory.count == nodes.count ? memory[offset] : nil)
      let text = card.map { $0.body.isEmpty ? $0.title : $0.body } ?? node.label
      return MemoryNote(
        id: node.id, fingerprint: card?.fingerprint ?? "",
        isAboutYou: node.memorySource == "profile" || card?.isAboutYou == true,
        text: text.trimmingCharacters(in: .whitespacesAndNewlines), timestamp: card?.timestamp ?? node.timestamp)
    }
  }

  /// Just the memories, linked to each other by what they say (`MemoryWeb.links`).
  public var memoryWeb: LearningGraph {
    let notes = memoryNotes
    let nodes = notes.map { LearningGraph.Node(id: $0.id, label: $0.text, kind: .memory) }
    return LearningGraph(nodes: nodes, edges: MemoryWeb.links(notes))
  }
}

/// Links between memories that talk about the same things: TF-IDF over their words (words in
/// only one memory say nothing about links), cosine similarity, each memory joined to its closest
/// two above `floor` and to any memory above `strong`.
public enum MemoryWeb {
  public static func links(_ notes: [MemoryNote], perNote: Int = 2, floor: Double = 0.15, strong: Double = 0.3)
    -> [LearningGraph.Edge]
  {
    let count = notes.count
    guard count > 1 else { return [] }
    let documents = notes.map { tokens($0.text) }
    var frequency: [String: Int] = [:]
    for document in documents {
      for word in Set(document) { frequency[word, default: 0] += 1 }
    }
    let vectors: [[String: Double]] = documents.map { document in
      var counts: [String: Int] = [:]
      for word in document { counts[word, default: 0] += 1 }
      var vector: [String: Double] = [:]
      for (word, n) in counts {
        let df = frequency[word] ?? 0
        guard df > 1 else { continue }
        vector[word] = (1 + log(Double(n))) * log(Double(1 + count) / Double(1 + df))
      }
      let norm = vector.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
      return norm > 0 ? vector.mapValues { $0 / norm } : [:]
    }

    var similarity = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
    for i in 0..<count {
      for j in (i + 1)..<count {
        let (small, large) = vectors[i].count <= vectors[j].count ? (vectors[i], vectors[j]) : (vectors[j], vectors[i])
        let value = small.reduce(0) { $0 + $1.value * (large[$1.key] ?? 0) }
        similarity[i][j] = value
        similarity[j][i] = value
      }
    }

    var pairs = Set<[Int]>()
    for i in 0..<count {
      let closest = (0..<count).filter { $0 != i && similarity[i][$0] >= floor }
        .sorted { similarity[i][$0] != similarity[i][$1] ? similarity[i][$0] > similarity[i][$1] : $0 < $1 }
        .prefix(perNote)
      for j in closest { pairs.insert([min(i, j), max(i, j)]) }
      for j in (i + 1)..<count where similarity[i][j] >= strong { pairs.insert([i, j]) }
    }
    return pairs.sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] }
      .map { LearningGraph.Edge(source: notes[$0[0]].id, target: notes[$0[1]].id) }
  }

  /// Lowercased words of two or more letters, without common words and bare numbers.
  static func tokens(_ text: String) -> [String] {
    text.lowercased()
      .split { !($0.isLetter || $0.isNumber) }
      .map(String.init)
      .filter { $0.count >= 2 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }
  }

  private static let stopWords: Set<String> = Set(
    """
    a an and are as at be but by for from has have he his her in into is it its of on or that the
    their them they this to was were will with not no only own per via any all can do does don
    doesn just than then there these those when where which who why how what also more most other
    some such so very too same each both few after before over under again further once here out
    up down off above below between through during while until about against you your yours our
    we us me my mine she him hers did done being been would should could may might must shall now
    new one two use used uses using like every never always keep keeps kept get gets got make makes
    made go goes going gone see seen want wants wanted
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}

/// Titles for memories. Hermes keeps a bot's memories as untitled paragraphs in two files
/// (MEMORY.md and USER.md), so a memory is named by its own opening words: plain string work,
/// no model.
public enum MemoryTitle {
  /// The first clause's first words, at most five, without a dangling "at", "in" or "his". A
  /// memory that starts with a short first line or a heading is titled by that line.
  public static func make(_ text: String) -> String {
    var line = text.split(separator: "\n").first.map(String.init) ?? text
    line = line.trimmingCharacters(in: .whitespaces)
    while let first = line.first, "#-*>".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
    line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    // "Ada (ada@example.com, ...) builds ...": an aside right after a short subject is dropped,
    // so the title is not cut inside it.
    if let open = line.range(of: " ("), line.distance(from: line.startIndex, to: open.lowerBound) < 8,
      let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
    {
      line.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
    }
    for stop in [". ", "; ", " (", ": ", " — ", " - ", " = ", ", "] {
      if let range = line.range(of: stop), line.distance(from: line.startIndex, to: range.lowerBound) >= 8 {
        line = String(line[..<range.lowerBound])
      }
    }
    var words: [String] = []
    for word in line.split(separator: " ").map(String.init) {
      // A path, an address or a link ends the title: it says where, not what.
      if !words.isEmpty, word.hasPrefix("/") || word.hasPrefix("~") || word.contains("://") || word.contains("@") { break }
      words.append(word)
      if words.count == 5 { break }
    }
    while words.count > 2, let last = words.last, trailing.contains(last.lowercased()) { words.removeLast() }
    var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))
    if title.isEmpty { return "Memory" }
    if let first = words.first, first.allSatisfy({ $0.isLowercase }) { title = title.prefix(1).uppercased() + title.dropFirst() }
    return title
  }

  private static let trailing: Set<String> = [
    "a", "an", "the", "at", "in", "on", "of", "to", "for", "and", "or", "with", "by", "from", "his", "her",
    "their", "its", "is", "are", "was", "own",
  ]
}
