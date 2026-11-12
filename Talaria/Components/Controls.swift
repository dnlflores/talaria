import HermesKit
import SwiftUI
import UIKit

/// A thin divider in the palette's separator color.
struct Hairline: View {
  @Environment(\.palette) private var palette

  var body: some View {
    Rectangle().fill(palette.border).frame(height: 1)
  }
}

/// Copies text and confirms with a checkmark for a moment.
struct CopyButton: View {
  let text: String
  var size: CGFloat = 13
  @State private var copied = false
  @Environment(\.palette) private var palette

  var body: some View {
    Button {
      UIPasteboard.general.string = text
      UISelectionFeedbackGenerator().selectionChanged()
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.4))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "square.on.square")
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(copied ? palette.success : palette.iconMuted)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(copied ? "Copied" : "Copy")
  }
}

/// A bot's picture, or a colored tile with its initial when it has none.
struct AvatarView: View {
  let profile: String
  var size: CGFloat = 18
  @Environment(AppModel.self) private var app

  var body: some View {
    Group {
      if let image = app.avatars[profile] {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        let hue = AvatarView.hue(for: profile)
        ZStack {
          LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.78), Color(hue: hue + 0.06, saturation: 0.7, brightness: 0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
          Text(String(app.title(forProfile: profile).prefix(1)).uppercased())
            .font(AppFont.sans(size * 0.56, .bold))
            .foregroundStyle(.white)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    .accessibilityHidden(true)
  }

  /// Stable per name (FNV-1a), so a bot keeps its color across launches.
  static func hue(for name: String) -> Double {
    var hash: UInt32 = 2_166_136_261
    for byte in name.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return Double(hash % 360) / 360
  }
}

/// Transient messages above the bottom bar.
struct ToastOverlay: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack {
      if let toast = app.toast {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: icon(toast.kind))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint(toast.kind))
          Text(toast.text)
            .font(AppFont.footnoteMedium)
            .foregroundStyle(palette.foreground)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onTapGesture { app.dismissToast() }
        .id(toast.id)
        .accessibilityAddTraits(.isStaticText)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 6)
    .animation(.spring(duration: 0.35), value: app.toast)
    .allowsHitTesting(app.toast != nil)
  }

  private func icon(_ kind: ToastMessage.Kind) -> String {
    switch kind {
    case .info: return "info.circle.fill"
    case .success: return "checkmark.circle.fill"
    case .failure: return "exclamationmark.triangle.fill"
    }
  }

  private func tint(_ kind: ToastMessage.Kind) -> Color {
    switch kind {
    case .info: return palette.primaryText
    case .success: return palette.success
    case .failure: return palette.dangerForeground
    }
  }
}

/// A small capsule label: "ALPHA" in T3 Code, connection state here.
struct TagLabel: View {
  let text: String
  var tint: Color?
  @Environment(\.palette) private var palette

  var body: some View {
    Text(text.uppercased())
      .font(AppFont.sans(10, .semibold))
      .kerning(0.8)
      .foregroundStyle(tint ?? palette.foregroundMuted)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background((tint ?? palette.foregroundMuted).opacity(0.12), in: Capsule())
  }
}

enum Format {
  /// "now", "9m", "3h", "2d", then a short date.
  static func ago(_ timestamp: Double, now: Date = Date()) -> String {
    guard timestamp > 0 else { return "" }
    let seconds = now.timeIntervalSince1970 - timestamp
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d" }
    return Date(timeIntervalSince1970: timestamp).formatted(.dateTime.month(.abbreviated).day())
  }

  static func clock(_ timestamp: Double?) -> String {
    guard let timestamp, timestamp > 0 else { return "" }
    let date = Date(timeIntervalSince1970: timestamp)
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }

  /// A model as people say it: `claude-opus-5-5` is "Opus 5.5".
  static func modelName(_ model: String) -> String {
    model.isEmpty ? "" : ModelName(model).display
  }

  /// `claude-opus-5-5` from `anthropic/claude-opus-5-5`.
  static func shortModel(_ model: String) -> String {
    model.split(separator: "/").last.map(String.init) ?? model
  }

  static func folder(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
  }

  static func bytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

extension View {
  /// Standard horizontal inset for screen content.
  func screenPadding() -> some View {
    padding(.horizontal, Metrics.screenPadding)
  }
}
