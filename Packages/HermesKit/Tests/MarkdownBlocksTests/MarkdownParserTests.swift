import Testing

@testable import MarkdownBlocks

@Suite struct MarkdownParserTests {
  @Test func paragraphsKeepTheirLineBreaks() {
    #expect(MarkdownParser.parse("one\ntwo\n\nthree") == [.paragraph("one\ntwo"), .paragraph("three")])
    #expect(MarkdownParser.parse("") == [])
    #expect(MarkdownParser.parse("\r\nwindows\r\nlines\r\n") == [.paragraph("windows\nlines")])
  }

  @Test func headingsAndRules() {
    #expect(MarkdownParser.parse("# Title\n## Sub ##\n---\ntext") == [
      .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .rule, .paragraph("text"),
    ])
    #expect(MarkdownParser.parse("#hashtag") == [.paragraph("#hashtag")])
    #expect(MarkdownParser.parse("* * *") == [.rule])
  }

  @Test func fencedCodeKeepsItsContentVerbatim() {
    let source = "Before\n```swift\nlet x = 1\n\n  indented()\n# not a heading\n```\nAfter"
    #expect(MarkdownParser.parse(source) == [
      .paragraph("Before"), .code(language: "swift", text: "let x = 1\n\n  indented()\n# not a heading"), .paragraph("After"),
    ])
  }

  @Test func anUnclosedFenceRunsToTheEnd() {
    #expect(MarkdownParser.parse("```\nstill streaming\n- not a list") == [.code(language: "", text: "still streaming\n- not a list")])
    #expect(MarkdownParser.parse("~~~py title\nx\n~~~~") == [.code(language: "py", text: "x")])
  }

  @Test func bulletListsNest() {
    let source = "- one\n- two\n  - inner a\n  - inner b\n- three"
    #expect(MarkdownParser.parse(source) == [
      .list(ordered: false, start: 1, items: [
        MarkdownListItem(blocks: [.paragraph("one")]),
        MarkdownListItem(blocks: [
          .paragraph("two"),
          .list(ordered: false, start: 1, items: [
            MarkdownListItem(blocks: [.paragraph("inner a")]), MarkdownListItem(blocks: [.paragraph("inner b")]),
          ]),
        ]),
        MarkdownListItem(blocks: [.paragraph("three")]),
      ])
    ])
  }

  @Test func orderedListsKeepTheirStartAndLooseItems() {
    let source = "3. third\n\n4. fourth\n   continues here\n\nplain"
    #expect(MarkdownParser.parse(source) == [
      .list(ordered: true, start: 3, items: [
        MarkdownListItem(blocks: [.paragraph("third")]), MarkdownListItem(blocks: [.paragraph("fourth\ncontinues here")]),
      ]),
      .paragraph("plain"),
    ])
  }

  @Test func listItemsCanHoldCodeAndParagraphs() {
    let source = "1. Run it:\n\n   ```sh\n   make test\n   ```\n\n   Then read the log.\n2. Done"
    #expect(MarkdownParser.parse(source) == [
      .list(ordered: true, start: 1, items: [
        MarkdownListItem(blocks: [.paragraph("Run it:"), .code(language: "sh", text: "make test"), .paragraph("Then read the log.")]),
        MarkdownListItem(blocks: [.paragraph("Done")]),
      ])
    ])
  }

  @Test func taskListsCarryTheirState() {
    #expect(MarkdownParser.parse("- [x] shipped\n- [ ] pending") == [
      .list(ordered: false, start: 1, items: [
        MarkdownListItem(blocks: [.paragraph("shipped")], checkbox: true),
        MarkdownListItem(blocks: [.paragraph("pending")], checkbox: false),
      ])
    ])
  }

  @Test func emphasisAtLineStartIsNotAList() {
    #expect(MarkdownParser.parse("**Bold** start\n*italic* too") == [.paragraph("**Bold** start\n*italic* too")])
  }

  @Test func aDifferentMarkerKindStartsANewList() {
    #expect(MarkdownParser.parse("- a\n1. b") == [
      .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("a")])]),
      .list(ordered: true, start: 1, items: [MarkdownListItem(blocks: [.paragraph("b")])]),
    ])
  }

  @Test func quotesNestBlocks() {
    #expect(MarkdownParser.parse("> quoted\n> - item\ncontinued\n\nafter") == [
      .quote([.paragraph("quoted"), .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("item\ncontinued")])])]),
      .paragraph("after"),
    ])
  }

  @Test func tablesSplitCells() {
    let source = "| Name | Value |\n|:-----|------:|\n| a \\| b | `1` |\n| c | |\nafter"
    #expect(MarkdownParser.parse(source) == [
      .table(header: ["Name", "Value"], rows: [["a | b", "`1`"], ["c", ""]]), .paragraph("after"),
    ])
    #expect(MarkdownParser.parse("a | b\nnot a separator") == [.paragraph("a | b\nnot a separator")])
  }

  @Test func tabsIndentNestedItems() {
    #expect(MarkdownParser.parse("- a\n\t- b") == [
      .list(ordered: false, start: 1, items: [
        MarkdownListItem(blocks: [.paragraph("a"), .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("b")])])])
      ])
    ])
  }
}
