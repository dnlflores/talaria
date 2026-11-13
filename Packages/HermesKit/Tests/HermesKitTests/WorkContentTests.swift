import Testing
@testable import HermesKit

@Suite struct WorkContentTests {
  @Test func whitespaceDoesNotCreateAnEmptyCommentaryBlock() {
    var item = TranscriptItem(kind: .assistant, text: " \n\t")
    item.reasoning = " \n"
    #expect(item.workContent.isEmpty)
  }

  @Test func reasoningAndCommentaryBothSurviveInReadingOrder() {
    var item = TranscriptItem(kind: .assistant, text: "I'll inspect **the file**.")
    item.reasoning = "  Check the smallest change first.\n"
    #expect(item.workContent == [.reasoning("Check the smallest change first."), .commentary("I'll inspect **the file**.")])
  }
}
