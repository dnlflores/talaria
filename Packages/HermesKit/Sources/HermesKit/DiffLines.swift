import Foundation

/// One line of an edit's diff, typed so the app can color it.
public struct DiffLine: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case added, removed
    /// `@@ -1,3 +1,4 @@`, and Hermes' "… omitted N diff line(s)" note.
    case hunk
    /// Which file the lines below belong to: Hermes' `a/x → b/x`, or a plain `--- a/x` / `+++ b/x`.
    case fileHeader
    case context
  }

  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }

  /// The line without its `+`, `-` or leading space, for reading aloud.
  public var content: String {
    switch kind {
    case .added, .removed, .context: return text.isEmpty ? text : String(text.dropFirst())
    case .hunk, .fileHeader: return text
    }
  }
}

/// The diff Hermes attaches to a file edit (`inline_diff`), cleaned and counted.
public struct EditDiff: Sendable, Hashable {
  /// Without color codes or Hermes' "review diff" heading.
  public let text: String
  public let added: Int
  public let removed: Int

  public init(_ raw: String) {
    text = DiffLines.clean(raw)
    (added, removed) = DiffLines.count(text)
  }

  public var lines: [DiffLine] { DiffLines.lines(text) }
  public var isEmpty: Bool { text.isEmpty }
}

/// Reads Hermes' rendered edit diffs. Hermes turns a unified diff into colored lines: a heading
/// (`  ┊ review diff`), one `a/path → b/path` line per file in place of `---`/`+++`, then the
/// hunks, and a closing "… omitted" note when it capped the length.
public enum DiffLines {
  /// Drops terminal color codes (`ESC[...m`).
  public static func stripANSI(_ text: String) -> String {
    text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
  }

  /// The diff as text to show and copy: no color codes, no heading, no trailing blank lines.
  public static func clean(_ raw: String) -> String {
    var lines = stripANSI(raw).split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
    // The heading is translated, but always starts with Hermes' dotted bar.
    if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("┊") { lines.removeFirst() }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    return lines.joined(separator: "\n")
  }

  public static func lines(_ text: String) -> [DiffLine] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map {
      DiffLine(kind: kind(of: Substring($0)), text: String($0))
    }
  }

  static func kind(of line: Substring) -> DiffLine.Kind {
    if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
    if line.hasPrefix("+") { return .added }
    if line.hasPrefix("-") { return .removed }
    if line.hasPrefix("@@") || line.hasPrefix("…") { return .hunk }
    if !line.hasPrefix(" "), line.contains(" → ") { return .fileHeader }
    return .context
  }

  /// Lines added and removed, the way the desktop app counts them (`countDiffLineStats`): a line
  /// starting with `+` but not `+++` is added, `-` but not `---` removed.
  public static func count(_ text: String) -> (added: Int, removed: Int) {
    var added = 0
    var removed = 0
    for line in stripANSI(text).split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+"), !line.hasPrefix("+++") {
        added += 1
      } else if line.hasPrefix("-"), !line.hasPrefix("---") {
        removed += 1
      }
    }
    return (added, removed)
  }

  /// The diff cut at each file header, each part with the path its header names (`b/` dropped;
  /// empty for lines before any header).
  static func sections(_ text: String) -> [(path: String, text: String)] {
    var out: [(path: String, lines: [Substring])] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if !line.hasPrefix(" "), !line.hasPrefix("+"), !line.hasPrefix("-"), let arrow = line.range(of: " → ") {
        out.append((headerPath(line[arrow.upperBound...]), [line]))
      } else if line.hasPrefix("--- ") {
        out.append(("", [line]))
      } else if line.hasPrefix("+++ "), !out.isEmpty {
        out[out.count - 1].path = headerPath(line.dropFirst(4))
        out[out.count - 1].lines.append(line)
      } else if out.isEmpty {
        out.append(("", [line]))
      } else {
        out[out.count - 1].lines.append(line)
      }
    }
    return out.map { ($0.path, $0.lines.joined(separator: "\n")) }
  }

  private static func headerPath(_ raw: Substring) -> String {
    var path = raw.trimmingCharacters(in: .whitespaces)
    if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
    return path
  }

  /// The one file among `files` that a header's path (often relative to the chat's folder) names.
  /// An exact match wins; otherwise the header and the file must end the same way, and only one
  /// file may do so. With `app.swift` and `lib/app.swift` both edited, the header `lib/app.swift`
  /// names the second file only, and a header that fits several files names none.
  static func file(namedBy header: String, among files: [String]) -> String? {
    let header = plain(header)
    guard !header.isEmpty, header != "/dev/null" else { return nil }
    if let exact = files.first(where: { plain($0) == header }) { return exact }
    let endingAlike = files.filter {
      let file = plain($0)
      return file.hasSuffix("/" + header) || header.hasSuffix("/" + file)
    }
    return endingAlike.count == 1 ? endingAlike[0] : nil
  }

  /// A path without a leading `./`.
  private static func plain(_ path: String) -> String {
    path.hasPrefix("./") ? String(path.dropFirst(2)) : path
  }
}
