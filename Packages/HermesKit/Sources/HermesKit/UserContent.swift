import Foundation

/// A user message as stored, split into what the person wrote and the pictures it carries.
///
/// Hermes keeps an attached picture as an `@image:<path>` line in the message text (the desktop
/// app turns those lines into the pictures themselves). A message sent with the picture inline
/// is flattened by the session store, which writes a `[screenshot]` line where each picture
/// was; next to an `@image:` line that placeholder only repeats it, so it goes too. A message
/// with no `@image:` line keeps any `[screenshot]` it has: then it is something the person typed.
public struct UserContent: Sendable, Equatable {
  public var text: String
  /// Paths on the Mac, in the order the message lists them.
  public var images: [String]

  public init(_ raw: String) {
    guard raw.contains("@image:") else {
      text = raw
      images = []
      return
    }
    var paths: [String] = []
    var kept: [Substring] = []
    var inFence = false
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
      if !inFence, let match = trimmed.wholeMatch(of: /@image:(`[^`]+`|"[^"]+"|'[^']+'|\S+)/) {
        let path = UserContent.unquote(String(match.1))
        if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        continue
      }
      kept.append(line)
    }
    if !paths.isEmpty {
      kept.removeAll { $0.trimmingCharacters(in: .whitespaces) == "[screenshot]" }
    }
    images = paths
    text = kept.joined(separator: "\n")
      .replacing(/\n{3,}/, with: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One line for a list: the words, or what was sent when it was only pictures. The backend's
  /// preview is the message on one line, cut short, so a reference can sit mid-line or end cut off.
  public static func preview(_ raw: String) -> String {
    guard raw.contains("@image:") else { return raw }
    var count = 0
    var text = raw.replacing(/@image:(`[^`]*`?|"[^"]*"?|'[^']*'?|\S*)/) { _ in
      count += 1
      return ""
    }
    text = text.replacing("[screenshot]", with: "").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    if text.isEmpty || text == "..." { return count == 1 ? "Image" : "\(count) images" }
    return text
  }

  /// A message sent into a running reply is stored inside an out-of-band wrapper meant for the
  /// model. The resumed transcript shows it unwrapped; stored rows need it done here.
  public static func unwrappingOutOfBand(_ raw: String) -> String {
    guard raw.hasPrefix("[OUT-OF-BAND USER MESSAGE") else { return raw }
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    lines.removeFirst()
    if let closing = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[/OUT-OF-BAND USER MESSAGE]" }) {
      lines.removeSubrange(closing...)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == value.last, "`\"'".contains(first) else { return value }
    return String(value.dropFirst().dropLast())
  }
}
