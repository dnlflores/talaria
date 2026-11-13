import Foundation

/// Independent work-log blocks: commentary must never hide reasoning on the same item.
public enum WorkContent: Sendable, Equatable {
  case reasoning(String)
  case commentary(String)
}

extension TranscriptItem {
  public var workContent: [WorkContent] {
    var blocks: [WorkContent] = []
    let thought = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    if !thought.isEmpty { blocks.append(.reasoning(thought)) }
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.commentary(text)) }
    return blocks
  }
}
