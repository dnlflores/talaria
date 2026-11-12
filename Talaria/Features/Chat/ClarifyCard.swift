import HermesKit
import SwiftUI

/// A question the agent asked, shown in the transcript so the question and the answer stay
/// in the conversation. A live one takes the answer in place; a past one shows what was picked.
struct ClarifyCard: View {
  let item: TranscriptItem
  let botTitle: String
  /// `(request id, answers per question)`; `nil` skips a question.
  let submit: (String, [[String]?]) -> Void

  @Environment(\.palette) private var palette
  @State private var selections: [Int: [String]] = [:]
  @State private var typed: [Int: String] = [:]

  var body: some View {
    if let tool = item.tool {
      let questions = tool.questions
      let pending = tool.pendingRequest
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 7) {
          Image(systemName: "questionmark.bubble")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(pending != nil ? palette.primaryText : palette.iconMuted)
          Text("\(botTitle) \(pending != nil ? "asks" : "asked")")
            .font(AppFont.labelMedium)
            .foregroundStyle(palette.foreground)
          Spacer(minLength: 8)
          Text(status(tool))
            .font(AppFont.caption)
            .foregroundStyle(pending != nil ? palette.primaryText : palette.foregroundMuted)
        }

        if questions.isEmpty {
          Text("The question was not recorded.")
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundMuted)
        }
        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
          questionView(index: index, question: question, tool: tool, questions: questions)
        }

        if let pending {
          HStack(spacing: 10) {
            Button("Skip") {
              submit(pending.id, Array(repeating: nil, count: questions.count))
            }
            .font(AppFont.footnoteMedium)
            .foregroundStyle(palette.foregroundSecondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(palette.secondary, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.secondaryBorder, lineWidth: 1) }
            Spacer(minLength: 0)
            Button(questions.count > 1 ? "Send answers" : "Send answer") {
              submit(pending.id, collected(questions))
            }
            .font(AppFont.footnoteMedium)
            .foregroundStyle(palette.prominentActionForeground)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(palette.prominentAction.opacity(hasAnswer(questions) ? 1 : 0.35), in: Capsule())
            .disabled(!hasAnswer(questions))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(pending != nil ? palette.primary.opacity(0.45) : palette.border, lineWidth: 1)
      }
    }
  }

  @ViewBuilder
  private func questionView(index: Int, question: ClarifyQuestion, tool: ToolCall, questions: [ClarifyQuestion]) -> some View {
    let pending = tool.pendingRequest
    let answer = recorded(for: question, at: index, in: tool)
    let chosen = pending != nil ? selections[index] ?? [] : answer?.values ?? []
    VStack(alignment: .leading, spacing: 8) {
      Text(question.question)
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(question.choices, id: \.self) { choice in
        let isOn = chosen.contains(choice)
        Button {
          guard let pending else { return }
          pick(choice, index: index, question: question, questions: questions, requestID: pending.id)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isOn ? (question.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill") : (question.multiSelect ? "square" : "circle"))
              .font(.system(size: 15))
              .foregroundStyle(isOn ? palette.primary : palette.iconMuted)
            Text(choice)
              .font(AppFont.footnote)
              .foregroundStyle(palette.foreground)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(isOn ? palette.primary.opacity(0.1) : palette.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(isOn ? palette.primary.opacity(0.5) : palette.border, lineWidth: 1)
          }
          .opacity(pending == nil && !chosen.isEmpty && !isOn ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(pending == nil)
        .accessibilityLabel(choice)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }

      if pending != nil {
        TextField(question.choices.isEmpty ? "Your answer" : "Something else", text: Binding(
          get: { typed[index] ?? "" }, set: { typed[index] = $0 }), axis: .vertical)
          .lineLimit(1...4)
          .font(AppFont.footnote)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(palette.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.inputBorder, lineWidth: 1) }
      } else if let answer {
        let own = answer.values.filter { !question.choices.contains($0) }
        if answer.skipped {
          Text("Skipped").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
        } else if !own.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            Text(question.choices.isEmpty ? "Answer" : "Your own answer")
              .font(AppFont.caption)
              .foregroundStyle(palette.foregroundMuted)
            Text(own.joined(separator: ", "))
              .font(AppFont.footnote)
              .foregroundStyle(palette.foreground)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func status(_ tool: ToolCall) -> String {
    if tool.pendingRequest != nil { return "Waiting for you" }
    if tool.isCancelled { return "No longer waiting" }
    if let answers = tool.answers, !answers.isEmpty { return answers.allSatisfy(\.skipped) ? "Skipped" : "Answered" }
    return tool.isDone ? "Answered" : "Asking"
  }

  private func recorded(for question: ClarifyQuestion, at index: Int, in tool: ToolCall) -> ClarifyAnswer? {
    guard let answers = tool.answers else { return nil }
    return answers.first { $0.question != nil && $0.question == question.question } ?? (index < answers.count ? answers[index] : nil)
  }

  private func pick(_ choice: String, index: Int, question: ClarifyQuestion, questions: [ClarifyQuestion], requestID: String) {
    var current = selections[index] ?? []
    if question.multiSelect {
      if let existing = current.firstIndex(of: choice) { current.remove(at: existing) } else { current.append(choice) }
    } else {
      current = [choice]
    }
    selections[index] = current
    // One question, one pick: that tap is the answer.
    let nothingTyped = (typed[0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if questions.count == 1, !question.multiSelect, nothingTyped {
      submit(requestID, [[choice]])
    }
  }

  private func collected(_ questions: [ClarifyQuestion]) -> [[String]?] {
    questions.enumerated().map { index, question in
      let picked = selections[index] ?? []
      let free = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if question.multiSelect {
        let all = picked + (free.isEmpty ? [] : [free])
        return all.isEmpty ? nil : all
      }
      if !free.isEmpty { return [free] }
      return picked.first.map { [$0] }
    }
  }

  private func hasAnswer(_ questions: [ClarifyQuestion]) -> Bool {
    collected(questions).contains { $0 != nil }
  }
}
