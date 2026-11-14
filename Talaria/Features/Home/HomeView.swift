import HermesKit
import SwiftUI

/// The inbox, grouped by bot as the Hermes mobile app lists agents: each bot with the latest
/// reply of its lead chat, the chats worth a look now hanging under it, and the rest one tap away.
struct HomeView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var query = ""
  @State private var showsBotPicker = false
  @State private var isStartingChat = false

  var body: some View {
    let groups = app.agentGroups(query: query)
    let heads = groups.compactMap(\.head)
    List {
      if let problem = connectionProblem {
        ConnectionBanner(text: problem)
          .listRowInsets(EdgeInsets(top: 4, leading: Metrics.screenPadding, bottom: 8, trailing: Metrics.screenPadding))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

      if app.originFilter != .all, app.hasLoadedSessions {
        OriginFilterBanner()
          .listRowInsets(EdgeInsets(top: 4, leading: Metrics.screenPadding, bottom: 4, trailing: Metrics.screenPadding))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

      if !app.hasLoadedSessions {
        ForEach(0..<5, id: \.self) { _ in
          AgentRowPlaceholder().treeRow()
        }
      } else if groups.isEmpty {
        EmptyInbox(isSearching: !query.isEmpty) { beginNewChat() }
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      } else {
        GroupHeading(text: "Agents")
          .padding(.horizontal, Metrics.screenPadding)
          .padding(.top, 4)
          .treeRow()
        ForEach(groups) { group in
          agentRows(group)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .screenBackground()
    .environment(\.defaultMinListRowHeight, 1)
    .refreshable { await app.refreshSessions() }
    .onAppear { Task { await app.refreshSessions(quiet: true) } }
    .task(id: heads.map { "\($0.id)@\($0.recency)" }) { await app.loadHeadPreviews(heads) }
    // A stack on iPad would fold search into a toolbar button; keep the field.
    .searchable(
      text: $query, placement: app.showsSideDock ? .navigationBarDrawer(displayMode: .always) : .automatic,
      prompt: "Search agents and sessions")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        HStack(spacing: 8) {
          // Both docks are icons only, so the inbox carries the wordmark everywhere.
          Wordmark()
          if let tag = ConnectionTag.current(app.connection) { TagLabel(text: tag.text, tint: tag.tint(palette)) }
        }
        .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)

      // The corner holds just two buttons: the filter by where chats started, and Settings
      // (the docks hold Chats and Agents only).
      ToolbarItem(placement: .topBarTrailing) {
        OriginFilterMenu()
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button {
          app.openArea(.settings)
        } label: {
          Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("home.settings")
      }
    }
    .sheet(isPresented: $showsBotPicker) {
      BotPickerSheet { profile in start(profile) }
        .presentationDetents([.medium, .large])
    }
  }

  // MARK: Rows

  /// A bot's block: its head row, the chats under it, and "N more sessions".
  @ViewBuilder
  private func agentRows(_ group: AgentGroup) -> some View {
    headRow(group)
    ForEach(Array(group.recent.enumerated()), id: \.element.id) { index, session in
      childRow(session, isLast: index == group.recent.count - 1 && group.moreCount == 0)
    }
    if group.moreCount > 0 {
      Button {
        app.showAgent(group.profile)
      } label: {
        AgentMoreRow(count: group.moreCount)
      }
      .buttonStyle(RowButtonStyle())
      .treeRow()
      .accessibilityLabel("\(group.moreCount) more \(app.title(forProfile: group.profile)) sessions")
      .accessibilityIdentifier("agent.more")
    }
  }

  private func headRow(_ group: AgentGroup) -> some View {
    let isSelected = app.usesSplitLayout && group.head != nil && app.selectedStoredID == group.head?.id
    let botTitle = app.title(forProfile: group.profile)
    return Button {
      if let head = group.head { app.open(head) } else { start(group.profile) }
    } label: {
      AgentHeadRow(group: group, preview: preview(for: group))
    }
    .buttonStyle(RowButtonStyle())
    .treeRow(selected: isSelected)
    .modifier(OptionalSwipeActions(session: group.head))
    .contextMenu {
      Button {
        start(group.profile)
      } label: {
        Label("New chat with \(botTitle)", systemImage: "square.and.pencil")
      }
      if group.head != nil {
        Button {
          app.showAgent(group.profile)
        } label: {
          Label("All sessions", systemImage: "list.bullet")
        }
      }
      Button {
        app.showBotPage(group.profile)
      } label: {
        Label("Agent hub", systemImage: "circle.grid.cross")
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(headLabel(group))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("session.row")
  }

  private func childRow(_ session: SessionSummary, isLast: Bool) -> some View {
    let isSelected = app.usesSplitLayout && app.selectedStoredID == session.id
    return Button {
      app.open(session)
    } label: {
      AgentChildRow(session: session, isLast: isLast)
    }
    .buttonStyle(RowButtonStyle())
    .treeRow(selected: isSelected)
    .modifier(SessionSwipeActions(session: session))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(SessionRow.title(of: session)), \(SessionStatusLabel.words(session, app: app))")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("session.row")
  }

  /// The lead chat's latest reply; its title until that has loaded.
  private func preview(for group: AgentGroup) -> String {
    guard let head = group.head else { return "No chats yet. Tap to start one." }
    if let reply = app.headPreviews[head.id], !reply.isEmpty { return reply }
    return SessionRow.title(of: head)
  }

  private func headLabel(_ group: AgentGroup) -> String {
    let bot = app.title(forProfile: group.profile)
    guard let head = group.head else { return "\(bot), no chats yet" }
    var parts = [bot, SessionRow.title(of: head), SessionStatusLabel.words(head, app: app)]
    if let reply = app.headPreviews[head.id], !reply.isEmpty { parts.append(reply) }
    if group.isPinned { parts.insert("Pinned", at: 1) }
    return parts.joined(separator: ", ")
  }

  // MARK: Chrome

  private var connectionProblem: String? {
    if case .closed(let reason) = app.connection, app.hasLoadedSessions {
      return "Can't reach your Mac. Retrying." + (reason.map { " \($0)" } ?? "")
    }
    if let error = app.sessionsError, app.sessions.isEmpty { return error }
    return nil
  }

  private func beginNewChat() {
    if app.profiles.count <= 1 {
      start(app.profiles.first?.name ?? "default")
    } else {
      showsBotPicker = true
    }
  }

  private func start(_ profile: String) {
    showsBotPicker = false
    guard !isStartingChat else { return }
    isStartingChat = true
    Task {
      await app.startChat(profile: profile)
      isStartingChat = false
    }
  }
}

private struct OptionalSwipeActions: ViewModifier {
  let session: SessionSummary?

  func body(content: Content) -> some View {
    if let session { content.modifier(SessionSwipeActions(session: session)) } else { content }
  }
}

extension View {
  /// A row of the bot tree: edge to edge, no separators, so the tree line runs unbroken.
  func treeRow(selected: Bool = false) -> some View {
    modifier(TreeRowStyle(selected: selected))
  }
}

private struct TreeRowStyle: ViewModifier {
  let selected: Bool
  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    content
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(selected ? palette.threadSelected : Color.clear)
  }
}

// MARK: - Row

struct SessionRow: View {
  let session: SessionSummary
  var isSelected = false
  /// Off in a bot's own list, where every row is the same bot: the top line names the source.
  var showsBot = true
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if showsBot {
          AvatarView(profile: session.profile, size: 16)
          Text(app.title(forProfile: session.profile))
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundSecondary)
            .lineLimit(1)
        } else {
          Image(systemName: sourceSymbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.iconMuted)
          Text(sourceName)
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundSecondary)
            .lineLimit(1)
        }
        if session.pinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.iconMuted)
        }
        Spacer(minLength: 8)
        SessionStatusLabel(session: session)
      }
      Text(SessionRow.title(of: session))
        .font(session.unread ? AppFont.bodySemibold : AppFont.body)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
      HStack(spacing: 6) {
        Text(meta)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        if app.preferences.hasDraft(for: session.id) {
          Text("Draft").font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
        }
        if showsBot {
          Image(systemName: sourceSymbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.iconMuted)
        }
      }
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// A chat's name: its title, else its first message.
  static func title(of session: SessionSummary) -> String {
    let base = session.baseTitle
    if !base.isEmpty { return base }
    return session.preview.isEmpty ? "New chat" : session.preview
  }

  /// `folder · branch` when the chat has a working folder, else the model.
  private var meta: String {
    var parts: [String] = []
    if !session.cwd.isEmpty { parts.append(session.cwd == app.macHome ? "~" : Format.folder(session.cwd)) }
    if !session.gitBranch.isEmpty { parts.append(session.gitBranch) }
    if !session.model.isEmpty { parts.append(Format.modelName(session.model)) }
    return parts.isEmpty ? SessionSection.sourceLabel(session.source) : parts.joined(separator: " · ")
  }

  private var sourceName: String {
    let origin = app.origin(of: session)
    if origin.origin != .unknown { return OriginBadge.words(origin) }
    switch session.section {
    case .chats:
      switch session.createdSource {
      case "desktop": return "Hermes app"
      case "cli", "tui": return "Terminal"
      default: return "Chat"
      }
    default: return SessionSection.sourceLabel(session.source)
    }
  }

  private var sourceSymbol: String {
    let origin = app.origin(of: session).origin
    if origin != .unknown { return origin.symbol }
    switch session.section {
    case .platform: return "number"
    case .api: return "curlybraces"
    case .runs:
      switch session.source {
      case "cron": return "clock"
      case "kanban": return "rectangle.split.3x1"
      case "subagent": return "person.2"
      default: return "bolt"
      }
    case .chats:
      switch session.createdSource {
      case "desktop": return "macbook"
      case "cli", "tui": return "apple.terminal"
      default: return "bubble.left"
      }
    }
  }
}

struct RowButtonStyle: ButtonStyle {
  @Environment(\.palette) private var palette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? palette.rowHover : Color.clear)
  }
}

private struct ConnectionBanner: View {
  let text: String
  @Environment(\.palette) private var palette

  var body: some View {
    Label(text, systemImage: "wifi.exclamationmark")
      .font(AppFont.label)
      .foregroundStyle(palette.warningForeground)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.warningBorder, lineWidth: 1) }
  }
}

private struct EmptyInbox: View {
  let isSearching: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: isSearching ? "magnifyingglass" : "bubble.left.and.text.bubble.right")
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(palette.iconMuted)
      Text(isSearching ? "No matches" : "No chats yet")
        .font(AppFont.headline)
        .foregroundStyle(palette.foreground)
      Text(isSearching ? "Try a different search." : "Start one here, or begin on your Mac and pick it up on the way.")
        .font(AppFont.footnote)
        .foregroundStyle(palette.foregroundMuted)
        .multilineTextAlignment(.center)
      if !isSearching {
        Button(action: action) {
          Text("New chat")
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

/// Picks which bot a new chat is with.
struct BotPickerSheet: View {
  let onPick: (String) -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(ordered.enumerated()), id: \.element.id) { offset, profile in
            if offset > 0 { Hairline().padding(.leading, 62) }
            Button {
              onPick(profile.name)
            } label: {
              HStack(spacing: 12) {
                AvatarView(profile: profile.name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                  Text(profile.title).font(AppFont.bodyMedium).foregroundStyle(palette.foreground)
                  Text(Format.modelName(profile.model))
                    .font(AppFont.mono(12))
                    .foregroundStyle(palette.foregroundMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(palette.chevron)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 12)
              .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
          }
        }
        .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
      }
      .navigationTitle("New chat with")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  /// The bot used last comes first.
  private var ordered: [Profile] {
    let last = app.preferences.lastProfile
    return app.profiles.sorted { a, b in
      if (a.name == last) != (b.name == last) { return a.name == last }
      if a.isDefault != b.isDefault { return a.isDefault }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }
}
