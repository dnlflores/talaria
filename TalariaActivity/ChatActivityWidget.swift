import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TalariaActivityBundle: WidgetBundle {
  var body: some Widget {
    ChatActivityWidget()
  }
}

/// A running reply on the Lock Screen and in the Dynamic Island.
struct ChatActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ChatActivityAttributes.self) { context in
      LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
        .activityBackgroundTint(nil)
        .widgetURL(context.attributes.url)
    } dynamicIsland: { context in
      let attributes = context.attributes
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            BotBadge(name: attributes.botName, size: 26)
            Text(attributes.botName)
              .font(.system(size: 15, weight: .semibold))
              .lineLimit(1)
          }
          .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          StatusText(state: state)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(StatusStyle.color(state.phase))
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 3) {
            Text(attributes.displayTitle(state))
              .font(.system(size: 14, weight: .medium))
              .lineLimit(1)
            if let detail = DetailText.text(state) {
              Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.bottom, 4)
        }
      } compactLeading: {
        BotBadge(name: attributes.botName, size: 22)
      } compactTrailing: {
        CompactStatus(state: state)
      } minimal: {
        MinimalStatus(state: state, botName: attributes.botName)
      }
      .widgetURL(attributes.url)
      .keylineTint(StatusStyle.color(state.phase))
    }
  }
}

// MARK: Pieces

private struct LockScreenView: View {
  let attributes: ChatActivityAttributes
  let state: ChatActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      BotBadge(name: attributes.botName, size: 38)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(attributes.botName)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 4)
          HStack(spacing: 5) {
            // A running timer says "working" well enough on its own.
            if state.phase != .working {
              Image(systemName: StatusStyle.symbol(state.phase))
                .font(.system(size: 12, weight: .semibold))
            }
            StatusText(state: state)
          }
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(StatusStyle.color(state.phase))
        }
        Text(attributes.displayTitle(state))
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let detail = DetailText.text(state) {
          Text(detail)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.top, 1)
        } else if isStale, !state.isOver {
          Text("No word from your Mac for a while")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(16)
  }
}

/// "Working 2:13", "Needs you", "Done in 4m".
private struct StatusText: View {
  let state: ChatActivityAttributes.ContentState

  var body: some View {
    switch state.phase {
    case .working:
      Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 64, alignment: .trailing)
    case .waiting:
      Text("Needs you")
    case .done:
      Text(DurationText.finished(state))
    case .failed:
      Text("Failed")
    case .stopped:
      Text("Stopped")
    }
  }
}

private struct CompactStatus: View {
  let state: ChatActivityAttributes.ContentState

  var body: some View {
    switch state.phase {
    case .working:
      Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
        .monospacedDigit()
        .font(.system(size: 14, weight: .medium))
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 46)
        .foregroundStyle(StatusStyle.color(.working))
    default:
      Image(systemName: StatusStyle.symbol(state.phase))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(StatusStyle.color(state.phase))
    }
  }
}

private struct MinimalStatus: View {
  let state: ChatActivityAttributes.ContentState
  let botName: String

  var body: some View {
    if state.phase == .working {
      BotBadge(name: botName, size: 22)
    } else {
      Image(systemName: StatusStyle.symbol(state.phase))
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(StatusStyle.color(state.phase))
    }
  }
}

/// The bot's initial on a color picked from its name, so each bot keeps one color.
struct BotBadge: View {
  let name: String
  var size: CGFloat

  var body: some View {
    Text(initial)
      .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: Circle())
      .accessibilityHidden(true)
  }

  private var initial: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "H"
  }

  private var color: Color {
    let palette: [Color] = [
      Color(red: 0.20, green: 0.42, blue: 0.95), Color(red: 0.86, green: 0.15, blue: 0.47),
      Color(red: 0.04, green: 0.44, blue: 0.46), Color(red: 0.56, green: 0.39, blue: 0.06),
      Color(red: 0.43, green: 0.27, blue: 0.85), Color(red: 0.85, green: 0.38, blue: 0.13),
    ]
    // A stable hash: String.hashValue changes from launch to launch.
    let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return palette[sum % palette.count]
  }
}

enum StatusStyle {
  static let accent = Color(red: 0.204, green: 0.420, blue: 0.945)

  static func color(_ phase: ChatActivityAttributes.Phase) -> Color {
    switch phase {
    case .working: return accent
    case .waiting: return .orange
    case .done: return .green
    case .failed: return .red
    case .stopped: return .secondary
    }
  }

  static func symbol(_ phase: ChatActivityAttributes.Phase) -> String {
    switch phase {
    case .working: return "ellipsis"
    case .waiting: return "questionmark.bubble.fill"
    case .done: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .stopped: return "stop.circle.fill"
    }
  }
}

enum DetailText {
  static func text(_ state: ChatActivityAttributes.ContentState) -> String? {
    let text = state.isOver ? (state.summary ?? state.step) : state.step
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }
}

enum DurationText {
  /// "Done in 42s", "Done in 4m", "Done in 1h 5m".
  static func finished(_ state: ChatActivityAttributes.ContentState) -> String {
    guard let end = state.endedAt else { return "Done" }
    let seconds = max(0, Int(end - state.startedAt))
    if seconds < 60 { return "Done in \(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "Done in \(minutes)m" }
    return "Done in \(minutes / 60)h \(minutes % 60)m"
  }
}

// MARK: Previews

#Preview("Lock Screen", as: .content, using: ChatActivityAttributes.preview) {
  ChatActivityWidget()
} contentStates: {
  ChatActivityAttributes.ContentState(phase: .working, startedAt: Date().timeIntervalSince1970 - 133, step: "Running a command")
  ChatActivityAttributes.ContentState(phase: .waiting, startedAt: Date().timeIntervalSince1970 - 300, step: "Should I open the PR now?")
  ChatActivityAttributes.ContentState(
    phase: .done, startedAt: Date().timeIntervalSince1970 - 260, endedAt: Date().timeIntervalSince1970,
    summary: "The flaky checkout test now waits for the cart to load. PR is up.")
}

extension ChatActivityAttributes {
  fileprivate static var preview: ChatActivityAttributes {
    ChatActivityAttributes(profile: "default", sessionID: "preview", botName: "Hermes", chatTitle: "Fix the flaky checkout test")
  }
}
