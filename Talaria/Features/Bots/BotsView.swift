import HermesKit
import SwiftUI

/// Bots: every Hermes profile on the Mac, and a page per bot with its model, soul and chats.
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
    .navigationTitle("Bots")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await app.refreshProfilesNow() }
  }

  private var ordered: [Profile] {
    app.profiles.sorted { a, b in
      if a.isDefault != b.isDefault { return a.isDefault }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }
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
    if !profile.model.isEmpty { parts.append(Format.shortModel(profile.model)) }
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

/// One bot's page.
struct BotDetailView: View {
  let name: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var soul: String?
  @State private var soulError: String?
  @State private var showsWholeSoul = false
  @State private var isOpeningBotChat = false
  @State private var isStartingChat = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        header
        actions
        if let profile {
          GroupedSection("Model") {
            ValueRow("Model", Format.shortModel(profile.model), mono: true)
            GroupDivider()
            ValueRow("Provider", profile.provider, mono: true)
            if profile.skillCount > 0 {
              GroupDivider()
              ValueRow("Skills", "\(profile.skillCount)")
            }
          }
        }
        soulSection
        recentChats
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle(profile?.title ?? name)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: name) { await loadSoul() }
  }

  private var profile: Profile? { app.profile(named: name) }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      AvatarView(profile: name, size: 64)
      VStack(alignment: .leading, spacing: 3) {
        Text(app.title(forProfile: name))
          .font(AppFont.title)
          .foregroundStyle(palette.foreground)
        Text(name)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
      }
      if let summary = profile?.summary, !summary.isEmpty {
        Text(summary)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundSecondary)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 4)
  }

  private var actions: some View {
    HStack(spacing: 10) {
      Button {
        Task { await openBotChat() }
      } label: {
        HStack(spacing: 6) {
          if isOpeningBotChat { ProgressView().controlSize(.small).tint(palette.prominentActionForeground) }
          Text("Bot Chat")
        }
        .font(AppFont.footnoteMedium)
        .foregroundStyle(palette.prominentActionForeground)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(palette.prominentAction, in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(isOpeningBotChat)
      .accessibilityHint("Opens the one standing chat this bot keeps")

      Button {
        isStartingChat = true
        Task {
          await app.startChat(profile: name)
          isStartingChat = false
        }
      } label: {
        HStack(spacing: 6) {
          if isStartingChat { ProgressView().controlSize(.small) }
          Text("New chat")
        }
        .font(AppFont.footnoteMedium)
        .foregroundStyle(palette.foregroundSecondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(palette.secondary, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.secondaryBorder, lineWidth: 1) }
      }
      .buttonStyle(.plain)
      .disabled(isStartingChat)
    }
    .padding(.horizontal, 4)
  }

  @ViewBuilder
  private var soulSection: some View {
    GroupedSection("Soul") {
      Group {
        if let soul {
          if soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("This bot has no standing instructions.")
              .font(AppFont.footnote)
              .foregroundStyle(palette.foregroundMuted)
          } else {
            VStack(alignment: .leading, spacing: 10) {
              MarkdownView(text: shownSoul(soul), style: .note)
                .textSelection(.enabled)
              if isLong(soul) {
                Button(showsWholeSoul ? "Show less" : "Show all") {
                  withAnimation(.snappy(duration: 0.25)) { showsWholeSoul.toggle() }
                }
                .font(AppFont.labelMedium)
                .foregroundStyle(palette.primaryText)
              }
            }
          }
        } else if let soulError {
          Text(soulError).font(AppFont.footnote).foregroundStyle(palette.dangerForeground)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            ForEach([220.0, 260.0, 160.0], id: \.self) { width in
              RoundedRectangle(cornerRadius: 4).fill(palette.subtle).frame(width: width, height: 11)
            }
          }
          .accessibilityLabel("Loading")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var recentChats: some View {
    let chats = app.sessions.filter { $0.profile == name && $0.section == .chats }
      .sorted { $0.recency > $1.recency }
    if !chats.isEmpty {
      GroupedSection("Recent chats", trailing: chats.count > 6 ? "\(chats.count) in all" : "") {
        ForEach(Array(chats.prefix(6).enumerated()), id: \.element.id) { offset, session in
          if offset > 0 { GroupDivider() }
          Button {
            app.openChat(profile: session.profile, storedID: session.id)
          } label: {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(session.baseTitle.isEmpty ? (session.preview.isEmpty ? "New chat" : session.preview) : session.baseTitle)
                  .font(AppFont.body)
                  .foregroundStyle(palette.foreground)
                  .lineLimit(1)
                Text(Format.ago(session.recency))
                  .font(AppFont.caption)
                  .foregroundStyle(palette.foregroundMuted)
              }
              Spacer(minLength: 8)
              if app.isWorking(session.id) { WorkingLabel() }
              Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.chevron)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
          }
          .buttonStyle(RowButtonStyle())
        }
      }
    }
  }

  private func isLong(_ text: String) -> Bool { text.count > 900 || text.split(separator: "\n").count > 18 }

  private func shownSoul(_ text: String) -> String {
    guard isLong(text), !showsWholeSoul else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(18).joined(separator: "\n")
    return String(lines.prefix(900)) + "\n\n…"
  }

  private func loadSoul() async {
    guard let client = app.client else { return }
    do {
      soul = try await client.soul(profile: name)
      soulError = nil
    } catch {
      soulError = "Could not load the soul: \(error.localizedDescription)"
    }
  }

  private func openBotChat() async {
    guard let client = app.client else { return }
    isOpeningBotChat = true
    defer { isOpeningBotChat = false }
    do {
      try await client.rpc.waitUntilReady(timeout: 30)
      let found = try await client.botChat(profile: name)
      if let live = found.created {
        app.openPrepared(live, profile: name)
        app.scheduleReload(after: 0.6)
      } else {
        app.openChat(profile: name, storedID: found.storedID)
      }
    } catch {
      app.show("Could not open Bot Chat: \(error.localizedDescription)", kind: .failure)
    }
  }
}
