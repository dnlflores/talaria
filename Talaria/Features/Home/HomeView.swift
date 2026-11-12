import HermesKit
import SwiftUI

/// The inbox: every conversation on the Mac, newest first, in T3 Code's three-line rows.
struct HomeView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var query = ""
  @State private var expanded: Set<SessionSection> = []
  @State private var showsBotPicker = false
  @State private var isStartingChat = false

  var body: some View {
    let chats = app.rows(in: .chats, query: query)
    List {
      if let problem = connectionProblem {
        ConnectionBanner(text: problem)
          .listRowInsets(EdgeInsets(top: 4, leading: Metrics.screenPadding, bottom: 8, trailing: Metrics.screenPadding))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

      if !app.hasLoadedSessions {
        ForEach(0..<7, id: \.self) { _ in
          SessionRowPlaceholder()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      } else if chats.isEmpty && shelves.isEmpty {
        EmptyInbox(isSearching: !query.isEmpty) { beginNewChat() }
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      } else {
        ForEach(chats) { session in row(session) }
        ForEach(shelves, id: \.section) { shelf in
          ShelfHeader(title: shelf.section.label, count: shelf.rows.count, isExpanded: isExpanded(shelf.section)) {
            toggle(shelf.section)
          }
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          if isExpanded(shelf.section) {
            ForEach(shelf.rows) { session in row(session) }
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.screen.ignoresSafeArea())
    .environment(\.defaultMinListRowHeight, 10)
    .refreshable { await app.refreshSessions() }
    .searchable(text: $query, prompt: "Search")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        HStack(spacing: 8) {
          Wordmark()
          if let tag = connectionTag { TagLabel(text: tag.text, tint: tag.tint) }
        }
        .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)

      ToolbarItem(placement: .topBarTrailing) { menu }

      DefaultToolbarItem(kind: .search, placement: .bottomBar)
      ToolbarSpacer(.fixed, placement: .bottomBar)
      ToolbarItem(placement: .bottomBar) {
        Button(action: beginNewChat) {
          if isStartingChat {
            ProgressView()
          } else {
            Image(systemName: "square.and.pencil")
          }
        }
        .disabled(isStartingChat)
        .accessibilityLabel("New chat")
      }
    }
    .sheet(isPresented: $showsBotPicker) {
      BotPickerSheet { profile in start(profile) }
        .presentationDetents([.medium, .large])
    }
  }

  // MARK: Rows

  private struct Shelf {
    let section: SessionSection
    let rows: [SessionSummary]
  }

  /// Everything that is not a chat you started: messaging threads, API calls, runs.
  private var shelves: [Shelf] {
    app.extraSections.compactMap { section in
      let rows = app.rows(in: section, query: query)
      return rows.isEmpty ? nil : Shelf(section: section, rows: rows)
    }
  }

  private func isExpanded(_ section: SessionSection) -> Bool {
    !query.isEmpty || expanded.contains(section)
  }

  private func toggle(_ section: SessionSection) {
    withAnimation(.snappy(duration: 0.25)) {
      if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
    }
  }

  private func row(_ session: SessionSummary) -> some View {
    Button {
      app.open(session)
    } label: {
      SessionRow(session: session)
    }
    .buttonStyle(RowButtonStyle())
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden, edges: .top)
    .listRowSeparatorTint(palette.border)
    .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.screenPadding }
    .accessibilityIdentifier("session.row")
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button {
        app.setPinned(session, !session.pinned)
      } label: {
        Label(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin")
      }
      .tint(palette.primary)
      Button {
        app.setUnread(session, !session.unread)
      } label: {
        Label(session.unread ? "Read" : "Unread", systemImage: session.unread ? "envelope.open" : "envelope.badge")
      }
      .tint(palette.foregroundMuted)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        withAnimation { app.archive(session) }
      } label: {
        Label("Archive", systemImage: "archivebox")
      }
      .tint(palette.warningForeground)
    }
  }

  // MARK: Chrome

  private var menu: some View {
    @Bindable var preferences = app.preferences
    return Menu {
      if app.profiles.count > 1 {
        Picker("Show", selection: $preferences.profileFilter) {
          Text("All bots").tag("")
          ForEach(app.profiles) { profile in
            Text(profile.title).tag(profile.name)
          }
        }
        .pickerStyle(.menu)
      }
      Button {
        app.path.append(.settings)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: app.preferences.profileFilter.isEmpty ? "ellipsis" : "line.3.horizontal.decrease")
    }
    .accessibilityLabel("More")
  }

  private var connectionTag: (text: String, tint: Color?)? {
    switch app.connection {
    case .open: return nil
    case .connecting, .idle: return ("Connecting", nil)
    case .closed: return ("Offline", palette.warningForeground)
    case .unauthorized: return ("Signed out", palette.dangerForeground)
    }
  }

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

// MARK: - Row

struct SessionRow: View {
  let session: SessionSummary
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        AvatarView(profile: session.profile, size: 16)
        Text(app.title(forProfile: session.profile))
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundSecondary)
          .lineLimit(1)
        if session.pinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.iconMuted)
        }
        Spacer(minLength: 8)
        status
      }
      Text(title)
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
        Image(systemName: sourceSymbol)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.iconMuted)
      }
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    let base = session.baseTitle
    if !base.isEmpty { return base }
    return session.preview.isEmpty ? "New chat" : session.preview
  }

  /// `folder · branch` when the chat has a working folder, else the model.
  private var meta: String {
    var parts: [String] = []
    if !session.cwd.isEmpty { parts.append(session.cwd == app.macHome ? "~" : Format.folder(session.cwd)) }
    if !session.gitBranch.isEmpty { parts.append(session.gitBranch) }
    if !session.model.isEmpty { parts.append(Format.shortModel(session.model)) }
    return parts.isEmpty ? SessionSection.sourceLabel(session.source) : parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var status: some View {
    if app.waitingOnYou.contains(session.id) {
      Text("Needs you").font(AppFont.labelMedium).foregroundStyle(palette.warningForeground)
    } else if session.isActive {
      // The backend's flag means "touched in the last five minutes", not "a reply is running",
      // so the label must not claim work is in progress.
      Text("Active").font(AppFont.label).foregroundStyle(palette.primaryText)
    } else if let owner = app.owners[session.id] {
      Text(owner.surface == "desktop" ? "Open on Mac" : "Open elsewhere")
        .font(AppFont.label)
        .foregroundStyle(palette.foregroundMuted)
    } else {
      HStack(spacing: 5) {
        if session.unread { Circle().fill(palette.primary).frame(width: 7, height: 7) }
        Text(Format.ago(session.recency)).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
      }
    }
  }

  private var sourceSymbol: String {
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

private struct SessionRowPlaceholder: View {
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RoundedRectangle(cornerRadius: 4).fill(palette.groupedCard).frame(width: 90, height: 11)
      RoundedRectangle(cornerRadius: 4).fill(palette.groupedCard).frame(maxWidth: 240).frame(height: 14)
      RoundedRectangle(cornerRadius: 4).fill(palette.groupedCard).frame(width: 150, height: 10)
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }
}

/// "Runs (34) ─────── ⌄": a collapsed group at the foot of the list, as T3 Code shelves snoozed threads.
private struct ShelfHeader: View {
  let title: String
  let count: Int
  let isExpanded: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text("\(title) (\(count))")
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundMuted)
        Rectangle().fill(palette.border).frame(height: 1)
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.chevron)
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
      }
      .padding(.horizontal, Metrics.screenPadding)
      .padding(.vertical, 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title), \(count)")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
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
                  Text(Format.shortModel(profile.model))
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
