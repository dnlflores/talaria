import Foundation
import Testing

@testable import HermesKit

/// Edit diffs as Hermes sends them in `inline_diff`: colored, under a "review diff" heading, with
/// one `a/x → b/x` line per file (the shape recorded from real `write_file` and `patch` calls).
@Suite struct DiffLinesTests {
  private static let esc = "\u{1B}"
  private static func paint(_ line: String, _ code: String) -> String { "\(esc)[\(code)m\(line)\(esc)[0m" }

  /// A recorded-shape diff for one file.
  private static func rendered(_ file: String, _ body: [String]) -> String {
    var lines = ["  ┊ review diff", paint("a/\(file) → b/\(file)", "38;2;218;165;32")]
    for line in body {
      let code = line.hasPrefix("+") ? "38;2;255;255;255;48;2;19;87;20"
        : line.hasPrefix("-") ? "38;2;255;255;255;48;2;120;20;20" : "38;2;139;134;130"
      lines.append(paint(line, code))
    }
    return lines.joined(separator: "\n")
  }

  private func tool(_ name: String, args: JSONValue, result: String = "", diff: String, error: Bool = false) -> TranscriptItem {
    var call = ToolCall(callID: UUID().uuidString, name: name, args: args, isDone: true)
    call.result = result
    call.inlineDiff = diff
    call.isError = error
    return .tool(call, timestamp: 50)
  }

  @Test func countsLikeTheDesktopApp() {
    let diff = "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n keep\n-old\n+new\n+also\n+++not counted\n---not counted"
    let counts = DiffLines.count(diff)
    #expect(counts.added == 2)
    #expect(counts.removed == 1)
  }

  @Test func stripsColorsAndTheHeading() {
    let raw = Self.rendered("proj/app.swift", ["@@ -1,2 +1,2 @@", " let a = 1", "-let b = 2", "+let b = 3"])
    #expect(DiffLines.stripANSI(Self.paint("+x", "1;32")) == "+x")
    let diff = EditDiff(raw)
    #expect(!diff.text.contains(Self.esc))
    #expect(!diff.text.contains("review diff"))
    #expect(diff.text.hasPrefix("a/proj/app.swift → b/proj/app.swift\n@@"))
    #expect(diff.added == 1)
    #expect(diff.removed == 1)
    #expect(EditDiff("").isEmpty)
    #expect(EditDiff("  ┊ review diff\n").isEmpty)
  }

  @Test func typesEachLine() {
    let diff = EditDiff(Self.rendered("a.txt", ["@@ -1,2 +1,2 @@", " same", "-gone", "+here", "… omitted 3 diff line(s)"]))
    #expect(diff.lines.map(\.kind) == [.fileHeader, .hunk, .context, .removed, .added, .hunk])
    #expect(diff.lines[3].content == "gone")
    #expect(diff.lines[4].content == "here")
    #expect(DiffLines.lines("--- a/x\n+++ b/x\n\\ No newline at end of file").map(\.kind) == [.fileHeader, .fileHeader, .context])
  }

  @Test func aWriteCarriesItsDiff() {
    let raw = Self.rendered("notes/plan.md", ["@@ -0,0 +1,3 @@", "+# Plan", "+", "+Ship it."])
    let files = FileExtraction.files(in: [
      tool("write_file", args: ["path": "notes/plan.md", "content": "x"],
           result: #"{"bytes_written": 1, "resolved_path": "/Users/me/proj/notes/plan.md"}"#, diff: raw),
    ])
    #expect(files.map(\.path) == ["/Users/me/proj/notes/plan.md"])
    #expect(files[0].diffs.count == 1)
    #expect(files[0].added == 3)
    #expect(files[0].removed == 0)
    #expect(files[0].hasChanges)
  }

  @Test func editsToOneFileAddUp() {
    let path = "/Users/me/proj/app.swift"
    let files = FileExtraction.files(in: [
      tool("patch", args: ["mode": "replace", "path": .string(path)], diff: Self.rendered("app.swift", ["@@ -1 +1 @@", "-a", "+b"])),
      tool("patch", args: ["mode": "replace", "path": .string(path)], diff: Self.rendered("app.swift", ["@@ -4 +4,2 @@", "+c", "+d"])),
      TranscriptItem(kind: .assistant, text: "Changed \(path).", timestamp: 60),
    ])
    #expect(files.count == 1)
    #expect(files[0].diffs.count == 2)
    #expect(files[0].added == 3)
    #expect(files[0].removed == 1)
  }

  @Test func aPatchOverTwoFilesIsSplitPerFile() {
    let patch = "*** Begin Patch\n*** Update File: /Users/me/proj/a.py\n-x\n+y\n*** Update File: /Users/me/proj/lib/b.py\n+z\n*** End Patch"
    let raw = Self.rendered("a.py", ["@@ -1 +1 @@", "-x", "+y"]) + "\n"
      + Self.paint("a/lib/b.py → b/lib/b.py", "38;2;218;165;32") + "\n" + Self.paint("@@ -0,0 +1 @@", "2") + "\n" + Self.paint("+z", "32")
    let files = FileExtraction.files(in: [tool("patch", args: ["mode": "patch", "patch": .string(patch)], diff: raw)])
    #expect(files.map(\.path) == ["/Users/me/proj/a.py", "/Users/me/proj/lib/b.py"])
    #expect(files.map(\.added) == [1, 1])
    #expect(files.map(\.removed) == [1, 0])
    #expect(files[1].diffs.first?.text.hasPrefix("a/lib/b.py → b/lib/b.py") == true)
  }

  @Test func aPatchDiffThatCannotBeSplitGoesToTheFirstFile() {
    let patch = "*** Begin Patch\n*** Update File: /Users/me/a.py\n+y\n*** Update File: /Users/me/b.py\n+z\n*** End Patch"
    let raw = "@@ -1 +1,2 @@\n+y\n+z"
    let files = FileExtraction.files(in: [tool("patch", args: ["mode": "patch", "patch": .string(patch)], diff: raw)])
    #expect(files.map(\.path) == ["/Users/me/a.py", "/Users/me/b.py"])
    #expect(files.map(\.added) == [2, 0])
    #expect(!files[1].hasChanges)
  }

  @Test func aFailedEditHasNoCounts() {
    let items = [
      tool("patch", args: ["mode": "replace", "path": "/Users/me/a.py"], result: "Error: no match", diff: "+x", error: true),
      tool("patch", args: ["mode": "replace", "path": "/Users/me/b.py"], result: #"{"success": false}"#, diff: ""),
    ]
    let files = FileExtraction.files(in: items)
    #expect(files.map(\.path) == ["/Users/me/b.py"])
    #expect(files[0].added == 0 && files[0].removed == 0)
    #expect(!files[0].hasChanges)
  }

  @Test func theChatListAddsUpEveryTurn() {
    let first = TurnFiles(id: UUID(), files: [FileReference(path: "/p/a.swift", origin: .edited, diffs: [EditDiff("+a\n-b")])])
    let second = TurnFiles(id: UUID(), files: [
      FileReference(path: "/p/a.swift", origin: .edited, diffs: [EditDiff("+c")]),
      FileReference(path: "/p/notes.md", origin: .mentioned),
    ])
    let files = TurnFiles.combined([first, second])
    #expect(files.map(\.path) == ["/p/a.swift", "/p/notes.md"])
    #expect(files[0].added == 2)
    #expect(files[0].removed == 1)
    #expect(files[0].diffs.count == 2)
  }
}
