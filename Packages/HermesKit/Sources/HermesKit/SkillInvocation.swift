import Foundation

/// A `/skill` turn is stored as the message Hermes built for the model, the whole skill body
/// included. The transcript shows what the person typed (`/work fix the leak`) instead.
///
/// `session.resume` does this itself; stored rows need it here. The markers mirror
/// `agent/skill_commands.py`, as the desktop app's `skill-scaffold.ts` does.
public enum SkillInvocation {
  static let prefix = "[IMPORTANT: The user has invoked the "
  static let singleMarker = "The full skill content is loaded below.]"
  static let singleInstruction = "The user has provided the following instruction alongside the skill invocation: "
  static let runtimeNote = "\n\n[Runtime note:"
  static let bundleMarker = " skill bundle,"
  static let bundleInstruction = "\nUser instruction: "
  static let bundleSkillBlock = "\n\n[Loaded as part of the "

  /// The invocation a stored skill turn came from, or nil for ordinary words.
  public static func text(_ stored: String) -> String? {
    guard stored.hasPrefix(prefix) else { return nil }
    let rest = stored.dropFirst(prefix.count)
    guard rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") else { return nil }
    let name = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    let label = name.hasPrefix("/") ? name : "/\(name)"
    let instruction: String
    if stored.contains(bundleMarker) {
      instruction = between(stored, bundleInstruction, bundleSkillBlock, fromEnd: false)
    } else if stored.contains(singleMarker) {
      instruction = between(stored, singleInstruction, runtimeNote, fromEnd: true)
    } else {
      instruction = ""
    }
    let words = instruction.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return words.isEmpty ? label : "\(label) \(words)"
  }

  private static func between(_ text: String, _ marker: String, _ end: String, fromEnd: Bool) -> String {
    guard let range = fromEnd ? text.range(of: marker, options: .backwards) : text.range(of: marker) else { return "" }
    let tail = text[range.upperBound...]
    let body = tail.range(of: end).map { tail[..<$0.lowerBound] } ?? tail
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
