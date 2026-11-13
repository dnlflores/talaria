import SwiftUI

/// A titled group of rows on a frosted card: settings, detail pages, the agent hub.
struct GroupedSection<Content: View>: View {
  let title: String
  var trailing: String = ""
  @ViewBuilder var content: Content
  @Environment(\.palette) private var palette

  init(_ title: String, trailing: String = "", @ViewBuilder content: () -> Content) {
    self.title = title
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if !title.isEmpty {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundMuted)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          if !trailing.isEmpty {
            Text(trailing).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
          }
        }
        .padding(.horizontal, 18)
      }
      VStack(alignment: .leading, spacing: 0) { content }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
  }
}

/// "FAVOURITES": 12 pt semibold, spaced capitals, the heading over a list.
struct GroupHeading: View {
  let text: String
  @Environment(\.palette) private var palette

  var body: some View {
    Text(text.uppercased())
      .font(AppFont.sans(12, .semibold))
      .kerning(1.6)
      .foregroundStyle(palette.foregroundMuted)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A label on the left and its value on the right. Machine values (ids, paths, schedules) are monospaced.
struct ValueRow: View {
  let label: String
  let value: String
  var isMono = false
  var valueColor: Color?
  var symbol: String?
  @Environment(\.palette) private var palette

  init(_ label: String, _ value: String, mono: Bool = false, color: Color? = nil, symbol: String? = nil) {
    self.label = label
    self.value = value
    isMono = mono
    valueColor = color
    self.symbol = symbol
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      if let symbol { RowSymbol(name: symbol) }
      Text(label).font(AppFont.body).foregroundStyle(palette.foreground)
      Spacer(minLength: 12)
      Text(value)
        .font(isMono ? AppFont.mono(13) : AppFont.footnote)
        .foregroundStyle(valueColor ?? palette.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 15)
    .accessibilityElement(children: .combine)
  }
}

/// A tappable row in a group: accent text with a symbol on the right.
struct ActionRow: View {
  let label: String
  let systemImage: String
  var isDestructive = false
  var isWorking = false
  let action: () -> Void
  @Environment(\.palette) private var palette

  init(_ label: String, systemImage: String, isDestructive: Bool = false, isWorking: Bool = false, action: @escaping () -> Void) {
    self.label = label
    self.systemImage = systemImage
    self.isDestructive = isDestructive
    self.isWorking = isWorking
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack {
        Text(label).font(AppFont.body)
        Spacer(minLength: 12)
        if isWorking {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
        }
      }
      .foregroundStyle(isDestructive ? palette.dangerForeground : palette.primaryText)
      .padding(.horizontal, 18)
      .padding(.vertical, 15)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
    .disabled(isWorking)
  }
}

/// A hairline between rows of a group, inset from the leading edge.
struct GroupDivider: View {
  var inset: CGFloat = 18
  @Environment(\.palette) private var palette

  var body: some View {
    Rectangle().fill(palette.separator).frame(height: 1).padding(.leading, inset)
  }
}

/// One headline, one muted line, and an optional small capsule action.
struct EmptyStateView: View {
  let symbol: String
  let title: String
  let text: String
  var actionTitle: String?
  var action: (() -> Void)?
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(palette.iconMuted)
      Text(title)
        .font(AppFont.headline)
        .foregroundStyle(palette.foreground)
      Text(text)
        .font(AppFont.footnote)
        .foregroundStyle(palette.foregroundMuted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(AppFont.footnoteMedium)
            .foregroundStyle(palette.prominentActionForeground)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(palette.prominentAction, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 90)
    .padding(.horizontal, 32)
  }
}

/// Placeholder rows in the shape of a three-line list row, while a list loads.
struct RowPlaceholder: View {
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RoundedRectangle(cornerRadius: 4).fill(palette.subtleStrong).frame(width: 90, height: 11)
      RoundedRectangle(cornerRadius: 4).fill(palette.subtleStrong).frame(maxWidth: 240).frame(height: 14)
      RoundedRectangle(cornerRadius: 4).fill(palette.subtleStrong).frame(width: 150, height: 10)
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }
}

extension Format {
  /// "in 5m", "in 3h", "in 2d" for a time ahead; `ago` for one behind.
  static func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = date.timeIntervalSince(now)
    if seconds < 0 { return ago(date.timeIntervalSince1970, now: now) }
    if seconds < 60 { return "in <1m" }
    if seconds < 3600 { return "in \(Int(seconds / 60))m" }
    if seconds < 86_400 { return "in \(Int(seconds / 3600))h" }
    return "in \(Int(seconds / 86_400))d"
  }

  /// "just now", "3m ago", "2d ago", "on Nov 3": a past time inside a sentence.
  static func agoPhrase(_ timestamp: Double, now: Date = Date()) -> String {
    let short = ago(timestamp, now: now)
    if short.isEmpty { return "" }
    if short == "now" { return "just now" }
    if now.timeIntervalSince1970 - timestamp >= 86_400 * 7 { return "on \(short)" }
    return "\(short) ago"
  }

  /// "0:07", "2:15", "1:02:03": elapsed time for a running turn.
  static func elapsed(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
  }
}
