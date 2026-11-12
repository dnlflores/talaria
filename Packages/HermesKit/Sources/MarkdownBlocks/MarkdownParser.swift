import Foundation

public struct MarkdownListItem: Equatable, Sendable {
  public var blocks: [MarkdownBlock]
  /// Task-list state: `nil` for a plain item.
  public var checkbox: Bool?

  public init(blocks: [MarkdownBlock], checkbox: Bool? = nil) {
    self.blocks = blocks
    self.checkbox = checkbox
  }
}

/// Block structure of a Markdown document. Inline markup stays as source text so the
/// view can hand it to `AttributedString(markdown:)`.
public indirect enum MarkdownBlock: Equatable, Sendable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case code(language: String, text: String)
  case list(ordered: Bool, start: Int, items: [MarkdownListItem])
  case quote([MarkdownBlock])
  case table(header: [String], rows: [[String]])
  case rule
}

/// A small block-level Markdown parser for chat transcripts.
///
/// It covers what agents write (paragraphs, headings, fenced code, nested lists, task
/// lists, quotes, tables, rules) and is tolerant of text that is still streaming:
/// an unclosed fence is a code block that runs to the end.
public enum MarkdownParser {
  private static let maxDepth = 6

  public static func parse(_ text: String) -> [MarkdownBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { expandLeadingTabs(String($0)) }
    return parse(lines, depth: 0)
  }

  // MARK: Blocks

  private static func parse(_ lines: [String], depth: Int) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var index = 0

    func flush() {
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
      }
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        flush()
        index += 1
        continue
      }
      let indent = leadingSpaces(line)

      if let fence = Fence(opening: trimmed) {
        flush()
        var code: [String] = []
        index += 1
        while index < lines.count {
          if fence.closes(lines[index].trimmingCharacters(in: .whitespaces)) {
            index += 1
            break
          }
          code.append(dropIndent(lines[index], upTo: indent))
          index += 1
        }
        blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
        continue
      }

      if let heading = heading(trimmed) {
        flush()
        blocks.append(heading)
        index += 1
        continue
      }

      if isRule(trimmed) {
        flush()
        blocks.append(.rule)
        index += 1
        continue
      }

      if trimmed.hasPrefix(">") {
        flush()
        var inner: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.isEmpty { break }
          if candidate.hasPrefix(">") {
            var rest = candidate.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            inner.append(String(rest))
          } else {
            inner.append(candidate)
          }
          index += 1
        }
        blocks.append(.quote(depth < maxDepth ? parse(inner, depth: depth + 1) : [.paragraph(inner.joined(separator: "\n"))]))
        continue
      }

      if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
        flush()
        let header = cells(trimmed)
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          if candidate.isEmpty || !candidate.contains("|") { break }
          rows.append(cells(candidate))
          index += 1
        }
        blocks.append(.table(header: header, rows: rows))
        continue
      }

      if let marker = ListMarker(line) {
        flush()
        let (list, next) = parseList(lines, from: index, first: marker, depth: depth)
        blocks.append(list)
        index = next
        continue
      }

      paragraph.append(trimmed)
      index += 1
    }
    flush()
    return blocks
  }

  // MARK: Lists

  private struct ListMarker {
    let indent: Int
    let ordered: Bool
    let number: Int
    /// Column where the item's text starts.
    let contentColumn: Int
    let content: String

    init?(_ line: String) {
      guard let match = line.firstMatch(of: /^( *)([-*+]|\d{1,9}[.)])( +)(.*)$/) else { return nil }
      indent = match.1.count
      let token = match.2
      ordered = token.first?.isNumber ?? false
      number = ordered ? Int(token.dropLast()) ?? 1 : 1
      contentColumn = indent + token.count + min(match.3.count, 4)
      content = String(match.4)
    }
  }

  private static func parseList(_ lines: [String], from start: Int, first: ListMarker, depth: Int) -> (MarkdownBlock, Int) {
    let base = first.indent
    func isSibling(_ marker: ListMarker) -> Bool {
      marker.indent >= base && marker.indent < base + 2 && marker.ordered == first.ordered
    }

    var items: [MarkdownListItem] = []
    var index = start
    while index < lines.count, let marker = ListMarker(lines[index]), isSibling(marker) {
      var body = [marker.content]
      index += 1
      while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
          // A blank line stays inside the item only when indented content follows it.
          var next = index + 1
          while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
          if next < lines.count, leadingSpaces(lines[next]) >= base + 2 {
            body.append("")
            index += 1
            continue
          }
          break
        }
        let indent = leadingSpaces(line)
        if let other = ListMarker(line), other.indent < base + 2 { break }
        if indent >= base + 2 {
          body.append(dropIndent(line, upTo: min(indent, marker.contentColumn)))
          index += 1
          continue
        }
        if startsBlock(trimmed) { break }
        body.append(trimmed)
        index += 1
      }

      var checkbox: Bool?
      if let match = body[0].firstMatch(of: /^\[([ xX])\] +(.*)$/) {
        checkbox = match.1 != " "
        body[0] = String(match.2)
      }
      let blocks = depth < maxDepth ? parse(body, depth: depth + 1) : [.paragraph(body.joined(separator: "\n"))]
      items.append(MarkdownListItem(blocks: blocks, checkbox: checkbox))

      // Blank lines between siblings keep the list going.
      var next = index
      while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
      if next < lines.count, let following = ListMarker(lines[next]), isSibling(following) {
        index = next
      } else {
        break
      }
    }
    return (.list(ordered: first.ordered, start: first.number, items: items), index)
  }

  // MARK: Line classification

  private struct Fence {
    let character: Character
    let length: Int
    let language: String

    init?(opening line: String) {
      guard let match = line.firstMatch(of: /^(`{3,}|~{3,})\s*([^`]*)$/) else { return nil }
      character = match.1.first ?? "`"
      length = match.1.count
      language = match.2.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    func closes(_ line: String) -> Bool {
      line.count >= length && line.allSatisfy { $0 == character }
    }
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*\s*$/) else { return nil }
    return .heading(level: match.1.count, text: String(match.2))
  }

  private static func isRule(_ line: String) -> Bool {
    line.wholeMatch(of: /([-*_])(\s*\1){2,}\s*/) != nil
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|"), trimmed.contains("-") else { return false }
    return trimmed.wholeMatch(of: /\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?/) != nil
  }

  private static func startsBlock(_ line: String) -> Bool {
    line.hasPrefix(">") || Fence(opening: line) != nil || heading(line) != nil || isRule(line)
  }

  private static func cells(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in line {
      if escaped {
        if character != "|" { current.append("\\") }
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    cells.append(current)
    var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
    if trimmed.first == "" { trimmed.removeFirst() }
    if trimmed.last == "" { trimmed.removeLast() }
    return trimmed
  }

  // MARK: Indentation

  private static func leadingSpaces(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
  }

  private static func dropIndent(_ line: String, upTo count: Int) -> String {
    String(line.dropFirst(min(count, leadingSpaces(line))))
  }

  private static func expandLeadingTabs(_ line: String) -> String {
    guard line.contains("\t") else { return line }
    var prefix = ""
    var rest = Substring(line)
    while let first = rest.first, first == " " || first == "\t" {
      prefix += first == "\t" ? "    " : " "
      rest = rest.dropFirst()
    }
    return prefix + rest
  }
}
