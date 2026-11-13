import HermesKit
import SwiftUI

/// Agents on iPad: every Hermes profile on the Mac. The one picked opens its hub beside the list.
struct BotsList: View {
  @Binding var selection: String?
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    List {
      if app.profiles.isEmpty {
        ForEach(0..<4, id: \.self) { _ in
          RowPlaceholder()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      } else {
        ForEach(ordered) { profile in
          let isSelected = app.usesSplitLayout && selection == profile.name
          Button {
            selection = profile.name
          } label: {
            BotRow(profile: profile)
          }
          .buttonStyle(RowButtonStyle())
          .listRowInsets(EdgeInsets())
          .listRowBackground(isSelected ? palette.threadSelected : Color.clear)
          .listRowSeparator(.hidden, edges: .top)
          .listRowSeparatorTint(palette.border)
          .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.screenPadding + 52 }
          .accessibilityIdentifier("bot.row")
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.screen.ignoresSafeArea())
    .environment(\.defaultMinListRowHeight, 10)
    .navigationTitle("Agents")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await app.refreshProfilesNow() }
  }

  private var ordered: [Profile] { app.orderedProfiles }
}

/// A bot as a list row: its picture, name and status, what it is for, and its model.
private struct BotRow: View {
  let profile: Profile
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(profile: profile.name, size: 40)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(profile.title)
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
          Spacer(minLength: 8)
          status
        }
        if !profile.summary.isEmpty {
          Text(profile.summary)
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(meta)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var chats: [SessionSummary] { app.sessions.filter { $0.profile == profile.name } }

  private var meta: String {
    var parts: [String] = []
    if !profile.model.isEmpty { parts.append(Format.modelName(profile.model)) }
    if let count = app.agentTotals[profile.name], count > 0 {
      parts.append(count == 1 ? "1 session" : "\(count.formatted()) sessions")
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var status: some View {
    if chats.contains(where: { app.isWorking($0.id) }) {
      WorkingLabel()
    } else if let latest = chats.map(\.recency).max(), latest > 0 {
      Text(Format.ago(latest)).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    }
  }
}
