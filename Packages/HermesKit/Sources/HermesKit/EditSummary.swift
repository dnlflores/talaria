import Foundation

/// A finished file edit as the conversation shows it on its own: what the call did, to which
/// files, and the diff Hermes attached.
public struct EditSummary: Sendable, Equatable {
  /// "Edited" for a patch, "Wrote" for a whole-file write.
  public let verb: String
  /// The files the call wrote or edited, in the order it named them.
  public let paths: [String]
  public let diff: EditDiff

  /// A call gets its own message once it finished cleanly with a diff. A running edit stays in
  /// the work log until then; a failed one has no diff and stays there too.
  /// Runs on every streamed token for every call in the chat, so it only scans for a change
  /// marker instead of cleaning the diff: a heading alone has no `+`, `-` or `@@`.
  public static func isShown(_ tool: ToolCall) -> Bool {
    tool.isDone && !tool.isError && !tool.isCancelled
      && tool.inlineDiff.contains { $0 == "+" || $0 == "-" || $0 == "@" }
  }

  public init?(_ tool: ToolCall) {
    guard Self.isShown(tool) else { return nil }
    let diff = EditDiff(tool.inlineDiff)
    guard !diff.isEmpty else { return nil }
    self.diff = diff
    var seen = Set<String>()
    paths = FileExtraction.toolFiles(tool).filter { $0.1 >= .edited }.map(\.0).filter { seen.insert($0).inserted }
    verb = tool.name.lowercased() == "write_file" ? "Wrote" : "Edited"
  }

  /// "Greeting.swift", "3 files", or "a file" when the call named none.
  public var subject: String {
    switch paths.count {
    case 0: return "a file"
    case 1: return FileReference(path: paths[0], origin: .edited).name
    default: return "\(paths.count) files"
    }
  }

  /// "Edited Greeting.swift".
  public var title: String { "\(verb) \(subject)" }
}
