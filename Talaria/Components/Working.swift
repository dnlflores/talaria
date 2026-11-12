import HermesKit
import SwiftUI

/// Three dots that take turns, the universal "someone is working on it". Still under Reduce Motion.
struct WorkingDots: View {
  var color: Color?
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let tint = color ?? palette.primary
    Group {
      if reduceMotion {
        dots(lit: nil, tint: tint)
      } else {
        PhaseAnimator([0, 1, 2]) { phase in
          dots(lit: phase, tint: tint)
        } animation: { _ in
          .easeInOut(duration: 0.32)
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func dots(lit: Int?, tint: Color) -> some View {
    HStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(tint)
          .frame(width: 5, height: 5)
          .opacity(lit == nil || lit == index ? 1 : 0.28)
          .scaleEffect(lit == index ? 1.15 : 1)
      }
    }
  }
}

/// "Working" for a list row: a reply is running there now.
struct WorkingLabel: View {
  /// When the turn began, if known: adds "3m" after the word.
  var since: Double?
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 5) {
      WorkingDots()
      Group {
        if let since {
          TimelineView(.periodic(from: .now, by: 20)) { context in
            Text(WorkingLabel.text(since: since, now: context.date.timeIntervalSince1970))
          }
        } else {
          Text("Working")
        }
      }
      .font(AppFont.labelMedium)
      .foregroundStyle(palette.primaryText)
      .monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Working")
  }

  /// "Working" under a minute, then "Working 3m", "Working 1h 5m".
  static func text(since: Double, now: Double) -> String {
    let minutes = Int((now - since) / 60)
    if minutes < 1 { return "Working" }
    if minutes < 60 { return "Working \(minutes)m" }
    return "Working \(minutes / 60)h \(minutes % 60)m"
  }
}

/// The line at the foot of a running turn: what the agent is doing and for how long.
/// It is on screen for the whole turn, whatever the rows above it show.
struct WorkingRow: View {
  let activity: TurnActivity
  let startedAt: Double?
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      WorkingDots(color: activity == .waiting ? palette.warningForeground : nil)
        .frame(width: 22, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          ShimmerText(text: label, font: AppFont.labelMedium)
            .lineLimit(1)
          if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(Format.elapsed(context.date.timeIntervalSince1970 - startedAt))
                .font(AppFont.mono(11))
                .foregroundStyle(palette.foregroundMuted)
                .monospacedDigit()
            }
          }
        }
        if !detail.isEmpty {
          Text(detail)
            .font(AppFont.mono(12))
            .foregroundStyle(palette.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Working: \(label)")
    .accessibilityIdentifier("transcript.working")
  }

  var label: String { WorkingRow.label(for: activity) }

  private var detail: String {
    guard case .running(let tool) = activity else { return "" }
    let text = tool.context.isEmpty ? tool.summary : tool.context
    return text.replacingOccurrences(of: "\n", with: " ")
  }

  static func label(for activity: TurnActivity) -> String {
    switch activity {
    case .thinking: return "Thinking"
    case .writing: return "Writing the answer"
    case .waiting: return "Waiting for you"
    case .running(let tool): return verb(for: tool.name)
    }
  }

  /// What a tool call is doing, said as a person would.
  static func verb(for name: String) -> String {
    switch name {
    case "terminal", "shell", "process", "process_manage": return "Running a command"
    case "execute_code": return "Running code"
    case "read_file": return "Reading a file"
    case "write_file": return "Writing a file"
    case "patch": return "Editing a file"
    case "search_files": return "Searching files"
    case "web_search": return "Searching the web"
    case "web_extract": return "Reading a page"
    case "delegate_task": return "Working with a helper"
    case "clarify": return "Asking you"
    case "vision_analyze": return "Looking at an image"
    case "text_to_speech": return "Making audio"
    default:
      if name.hasPrefix("browser") { return "Using the browser" }
      if name.contains("skill") { return "Reading a skill" }
      if name.contains("memory") || name.contains("notes") { return "Checking memory" }
      return "Using \(ToolPresentation.title(for: name).lowercased())"
    }
  }
}
