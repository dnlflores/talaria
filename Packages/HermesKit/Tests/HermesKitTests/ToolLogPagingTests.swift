import Foundation
import Testing
@testable import HermesKit

@Suite struct ToolLogPagingTests {
  private func log(_ count: Int) -> WorkLog {
    WorkLog(id: UUID(), items: (1...count).map {
      .tool(ToolCall(callID: "call-\($0)", name: "read_file", args: ["path": .string("file-\($0).swift")], isDone: true))
    }, isLive: false, seconds: nil)
  }

  @Test func exposesOnlyFirstTwentyThenNextTwentyUntilExhausted() {
    let log = log(45)
    #expect(log.page(toolLimit: 20).compactMap(\.tool).map(\.callID) == (1...20).map { "call-\($0)" })
    #expect(log.page(toolLimit: 40).compactMap(\.tool).map(\.callID) == (1...40).map { "call-\($0)" })
    #expect(log.page(toolLimit: 60).compactMap(\.tool).map(\.callID) == (1...45).map { "call-\($0)" })
  }

  @Test func reasoningDoesNotConsumeTheToolAllowance() {
    var log = log(21)
    var thought = TranscriptItem(kind: .assistant)
    thought.reasoning = "Actual private reasoning"
    log.items.insert(thought, at: 4)
    #expect(log.page(toolLimit: 20).count == 21)
    #expect(log.page(toolLimit: 20).compactMap(\.tool).count == 20)
    #expect(log.page(toolLimit: 20).last?.tool?.callID == "call-20")
    #expect(log.page(toolLimit: 40).count == 22)
  }

  @Test func exactPageAndSmallGroupsNeedNoMoreRows() {
    for count in [1, 19, 20] {
      let log = log(count)
      #expect(log.page(toolLimit: 20) == log.items)
    }
  }
}
