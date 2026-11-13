import Foundation
import Testing
@testable import HermesKit

@Suite struct ProviderDisplayTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TALARIA_DISPLAY_ROWS"] != nil))
  func recordedTranscriptKeepsEveryProjectedPublicUpdate() throws {
    let path = try #require(ProcessInfo.processInfo.environment["TALARIA_DISPLAY_ROWS"])
    let json = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: path)))
    let rows = try #require(json["messages"].array)
    let updates = rows.flatMap { $0["display_commentary"].array ?? [] }.compactMap(\.string)
    #expect(!updates.isEmpty, "the recorded chat must include actual projected GPT commentary")
    let items = TranscriptItem.items(fromStoredRows: rows)
    for update in updates { #expect(items.contains { $0.kind == .assistant && $0.text == update }) }
    #expect(!items.contains { $0.kind == .system && $0.text.contains("[INTERNAL NOTIFICATION") })
  }
  @Test func gptPublicCommentaryUsesTheGatewayProjectionNotRawReasoning() {
    let row: JSONValue = ["role": "assistant", "content": "", "reasoning": "Private.\n\nI found the cause.",
      "display_commentary": ["I found the cause."], "display_reasoning": "Private.",
      "tool_calls": [["id": "call", "function": ["name": "read_file", "arguments": "{}"]]]]
    let items = TranscriptItem.items(fromStoredRows: [row])
    #expect(items.filter { $0.kind == .assistant }.map(\.text) == ["I found the cause."])
    #expect(items.filter { $0.kind == .assistant }.map(\.reasoning) == ["Private."])
    #expect(items.last?.tool?.callID == "call")
  }

  @Test func gatewayHistoryAndStoredRowsHaveTheSamePublicWords() {
    let fields: JSONValue = ["role": "assistant", "text": "Done.", "content": "Done.",
      "reasoning": "Internal and public text flattened together", "display_reasoning": "Internal.",
      "display_commentary": ["First update.", "Second update."]]
    for items in [TranscriptItem.items(fromHistory: [fields]), TranscriptItem.items(fromStoredRows: [fields])] {
      #expect(items.map(\.text) == ["First update.", "Second update.", "Done."])
      #expect(items.map(\.reasoning) == ["Internal.", "", ""])
    }
  }

  @Test func emptyProjectedReasoningAndCommentaryAreAuthoritative() {
    let row: JSONValue = ["role": "assistant", "content": "Done.", "reasoning": "Old raw words.",
      "display_reasoning": "", "display_commentary": [],
      "codex_message_items": [["type": "message", "role": "assistant", "phase": "commentary",
        "content": [["type": "output_text", "text": "Must not recover raw sidecar text."]]]]]
    let items = TranscriptItem.items(fromStoredRows: [row])
    #expect(items.map(\.text) == ["Done."])
    #expect(items.map(\.reasoning) == [""])
  }

  @Test func explicitEmptyContentNeverFallsBackToRawWords() {
    let row: JSONValue = ["role": "assistant", "content": "Must stay hidden.", "text": "Must stay hidden.",
      "display_content": "", "display_reasoning": "", "display_commentary": []]
    for items in [TranscriptItem.items(fromHistory: [row]), TranscriptItem.items(fromStoredRows: [row])] {
      #expect(items.allSatisfy { $0.text.isEmpty && $0.reasoning.isEmpty })
    }
  }

  @Test func hiddenProjectedWordsStayHiddenButToolResultsRemainInspectable() {
    let rows: [JSONValue] = [
      ["role": "assistant", "display_kind": "hidden", "content": "Private words.",
       "display_commentary": ["Withheld public update."], "display_reasoning": "Private thought.",
       "tool_calls": [["id": "hidden-call", "function": ["name": "read_file", "arguments": "{}"]]]],
      ["role": "tool", "tool_call_id": "hidden-call", "content": "Recorded result."],
    ]
    let items = TranscriptItem.items(fromStoredRows: rows)
    #expect(items.count == 1)
    #expect(items.first?.tool?.result == "Recorded result.")
    #expect(items.first?.tool?.isDone == true)
  }

  @Test func projectedCommentaryAloneIsNotPromotedToAnAnswer() {
    let items = TranscriptItem.items(fromStoredRows: [[
      "role": "assistant", "content": "", "display_reasoning": "", "display_commentary": ["Still checking."],
    ]])
    let rows = TranscriptLayout.rows(for: items, isStreaming: false)
    #expect(rows.count == 1)
    guard case .commentary(let note) = rows.first else { Issue.record("projected update became an answer"); return }
    #expect(note.text == "Still checking.")
  }

  @Test func internalMachineryDoesNotBecomeChatMessages() {
    for kind in ["internal_notification", "process_complete", "async_delegation_complete"] {
      let row: JSONValue = ["role": "user", "content": "[IMPORTANT: internal machinery]", "text": "[IMPORTANT: internal machinery]",
        "display_kind": .string(kind)]
      #expect(TranscriptItem.items(fromStoredRows: [row]).isEmpty)
      #expect(TranscriptItem.items(fromHistory: [row]).isEmpty)
    }
    // Never hide an actual person's words merely because they resemble a marker.
    let user: JSONValue = ["role": "user", "content": "[IMPORTANT: my instructions]", "text": "[IMPORTANT: my instructions]"]
    #expect(TranscriptItem.items(fromStoredRows: [user]).first?.kind == .user)
    #expect(TranscriptItem.items(fromHistory: [user]).first?.kind == .user)
  }
}
