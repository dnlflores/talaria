import HermesKit
import SwiftUI

/// Three dots that take turns, the universal "someone is working on it". Still under Reduce Motion.
struct WorkingDots: View {
  var color: Color?
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How long each dot holds the light before handing it to the next, in seconds.
  static let beat = 0.32

  var body: some View {
    let tint = color ?? palette.primary
    // Driven by the clock rather than by animated state changes. Every phase change of an
    // animation here also animated the dots' position when their row moved in the same update
    // (a streamed line wrapping), so the dots trailed behind their row or hung in empty space.
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
      dots(tint: tint, beat: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate / Self.beat)
    }
    .accessibilityHidden(true)
  }

  private func dots(tint: Color, beat: Double?) -> some View {
    HStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { index in
        let lit = beat.map { Self.lit(index, beat: $0) }
        Circle()
          .fill(tint)
          .frame(width: 5, height: 5)
          .opacity(lit.map { 0.28 + 0.72 * $0 } ?? 1)
          .scaleEffect(1 + 0.15 * (lit ?? 0))
      }
    }
  }

  /// 1 while dot `index` holds the light, easing to 0 as it passes to a neighbour.
  static func lit(_ index: Int, beat: Double) -> Double {
    let position = beat.truncatingRemainder(dividingBy: 3)
    let distance = abs(position - Double(index))
    let t = max(0, 1 - min(distance, 3 - distance))
    return t * t * (3 - 2 * t)
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
    return tool.preview
  }

  static func label(for activity: TurnActivity) -> String {
    switch activity {
    case .thinking: return "Thinking"
    // Text that is streaming may be a note before the next step or the answer itself.
    case .writing: return "Writing"
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
