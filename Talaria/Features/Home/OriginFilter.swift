import HermesKit
import SwiftUI

// Prototype: where a chat started (Hermes app, Talaria, terminal, Workdash, Slack, automation),
// from the Mac's backfill. Shown as a small icon on rows and as an inbox filter.

/// The filter button in the inbox's top bar: a menu of origins with how many loaded chats each has.
struct OriginFilterMenu: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    let counts = app.originCounts()
    Menu {
      Picker("Show", selection: $app.originFilter) {
        ForEach(ChatOriginFilter.menu.filter { $0 == .all || $0 == .personal || (counts[$0] ?? 0) > 0 }, id: \.self) { filter in
          Label("\(filter.label)  \(counts[filter] ?? 0)", systemImage: filter.symbol).tag(filter)
        }
      }
      .pickerStyle(.inline)
      if !app.chatOrigins.generatedAt.isEmpty {
        Text("Tagged on your Mac \(OriginFilterMenu.stamp(app.chatOrigins.generatedAt))")
      }
    } label: {
      Image(systemName: app.originFilter == .all
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
    }
    .accessibilityLabel("Filter by where chats started")
    .accessibilityIdentifier("home.originFilter")
  }

  /// "9:24 PM" for today, else the date.
  static func stamp(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    return Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .shortened)
  }
}

/// "Showing Talaria · 8" with a clear button, above the list while a filter is on.
struct OriginFilterBanner: View {
  var showsCount = true
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    let filter = app.originFilter
    HStack(spacing: 8) {
      Image(systemName: filter.symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.primaryText)
      Text(showsCount ? "Showing \(filter.label) · \(app.originCounts()[filter] ?? 0)" : "Showing \(filter.label)")
        .font(AppFont.labelMedium)
        .foregroundStyle(palette.foreground)
      Spacer(minLength: 8)
      Button {
        app.originFilter = .all
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 15))
          .foregroundStyle(palette.iconMuted)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Show all chats")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(palette.primaryText.opacity(0.08), in: Capsule())
  }
}

/// A chat's origin as a small icon. Guesses are drawn fainter.
struct OriginBadge: View {
  let tag: ChatOriginTag
  @Environment(\.palette) private var palette

  var body: some View {
    Image(systemName: tag.origin.symbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(palette.iconMuted.opacity(tag.confidence == .guess ? 0.55 : 1))
      .frame(width: 16)
      .accessibilityLabel(OriginBadge.words(tag))
  }

  /// "Talaria", "Slack", "Automation · cron", with "probably" for a guess.
  static func words(_ tag: ChatOriginTag) -> String {
    var text = tag.origin.label
    if tag.origin == .messaging, !tag.detail.isEmpty { text = SessionSection.sourceLabel(tag.detail) }
    if tag.origin == .automation, !tag.detail.isEmpty { text += " · \(SessionSection.sourceLabel(tag.detail))" }
    if tag.origin == .test, !tag.detail.isEmpty { text += " · \(tag.detail)" }
    return tag.confidence == .guess ? "\(text)?" : text
  }
}
