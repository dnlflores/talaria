import HermesKit
import SwiftUI

// MARK: - Geometry

/// Where the avatar sits and where the tree line runs, shared by every row of a bot's block.
enum TreeMetrics {
  static let avatar: CGFloat = 46
  static let headTop: CGFloat = 14
  static var lineX: CGFloat { Metrics.screenPadding + avatar / 2 }
  static var textLeading: CGFloat { Metrics.screenPadding + avatar + 12 }
  static let radius: CGFloat = 10
}

/// The thin line that joins a bot to the chats under it: down from the avatar, through each
/// chat, and into the last row with a rounded corner.
struct TreeConnector: Shape {
  enum Kind {
    case fromAvatar
    case through
    case end
  }

  let kind: Kind

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let x = TreeMetrics.lineX
    switch kind {
    case .fromAvatar:
      path.move(to: CGPoint(x: x, y: TreeMetrics.headTop + TreeMetrics.avatar + 5))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))
    case .through:
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))
    case .end:
      let radius = TreeMetrics.radius
      let middle = rect.midY
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: middle - radius))
      path.addQuadCurve(to: CGPoint(x: x + radius, y: middle), control: CGPoint(x: x, y: middle))
      path.addLine(to: CGPoint(x: TreeMetrics.textLeading - 8, y: middle))
    }
    return path
  }
}

private struct TreeLine: View {
  let kind: TreeConnector.Kind
  @Environment(\.palette) private var palette

  var body: some View {
    TreeConnector(kind: kind)
      .stroke(palette.border, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .accessibilityHidden(true)
  }
}

// MARK: - Rows

/// A bot: its picture and name, and the latest reply of its lead chat.
struct AgentHeadRow: View {
  let group: AgentGroup
  let preview: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(profile: group.profile, size: TreeMetrics.avatar)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if group.isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(palette.warningForeground)
          }
          Text(app.title(forProfile: group.profile))
            .font(AppFont.sans(17, .semibold))
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
          Spacer(minLength: 8)
          if let head = group.head { SessionStatusLabel(session: head) }
        }
        Text(preview)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
      }
      .padding(.top, 2)
    }
    .padding(.leading, Metrics.screenPadding)
    .padding(.trailing, 34)
    .padding(.top, TreeMetrics.headTop)
    .padding(.bottom, group.hasTail ? 8 : TreeMetrics.headTop)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) { Chevron().padding(.trailing, 14) }
    .background { if group.hasTail { TreeLine(kind: .fromAvatar) } }
    .contentShape(Rectangle())
  }
}

/// A chat under its bot: one line with its state on the right.
struct AgentChildRow: View {
  let session: SessionSummary
  let isLast: Bool
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      Text(SessionRow.title(of: session))
        .font(session.unread ? AppFont.bodySemibold : AppFont.body)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
      Spacer(minLength: 8)
      SessionStatusLabel(session: session)
      Chevron()
    }
    .padding(.leading, TreeMetrics.textLeading)
    .padding(.trailing, 14)
    .padding(.vertical, 11)
    .background { TreeLine(kind: isLast ? .end : .through) }
    .padding(.bottom, isLast ? 2 : 0)
    .contentShape(Rectangle())
  }
}

/// "131 more sessions": the rest of a bot's chats, one tap away.
struct AgentMoreRow: View {
  let count: Int
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      Text(count == 1 ? "1 more session" : "\(count.formatted()) more sessions")
        .font(AppFont.label)
        .foregroundStyle(palette.foregroundMuted)
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.chevron)
      Spacer(minLength: 0)
    }
    .padding(.leading, TreeMetrics.textLeading)
    .padding(.vertical, 9)
    .background { TreeLine(kind: .end) }
    .padding(.bottom, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

private struct Chevron: View {
  @Environment(\.palette) private var palette

  var body: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(palette.chevron)
      .accessibilityHidden(true)
  }
}

/// A chat's state in a word or two: needs you, working (and for how long), or when it last
/// moved, with a dot when unread.
struct SessionStatusLabel: View {
  let session: SessionSummary
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    if app.needsYou(session.id) {
      Text("Needs you").font(AppFont.labelMedium).foregroundStyle(palette.warningForeground)
    } else if app.isWorking(session.id) {
      WorkingLabel(since: app.workingStart(session.id))
    } else {
      HStack(spacing: 5) {
        if session.unread { Circle().fill(palette.primary).frame(width: 7, height: 7) }
        Text(Format.agoPhrase(session.recency))
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundMuted)
      }
    }
  }

  /// The same, in words for VoiceOver and UI tests.
  @MainActor static func words(_ session: SessionSummary, app: AppModel) -> String {
    if app.needsYou(session.id) { return "Needs you" }
    if app.isWorking(session.id) { return "Working" }
    let when = Format.agoPhrase(session.recency)
    return session.unread ? "Unread, \(when)" : when
  }
}

/// A bot-shaped placeholder while the inbox loads.
struct AgentRowPlaceholder: View {
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: TreeMetrics.avatar * 0.28, style: .continuous)
        .fill(palette.groupedCard)
        .frame(width: TreeMetrics.avatar, height: TreeMetrics.avatar)
      VStack(alignment: .leading, spacing: 9) {
        RoundedRectangle(cornerRadius: 4).fill(palette.groupedCard).frame(width: 110, height: 13)
        RoundedRectangle(cornerRadius: 4).fill(palette.groupedCard).frame(maxWidth: 240).frame(height: 11)
      }
      .padding(.top, 6)
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, TreeMetrics.headTop)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }
}

// MARK: - One bot's chats

/// Every conversation of one bot, newest first, loaded a page at a time.
struct AgentSessionsView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var rows: [SessionSummary] = []
  @State private var fetched = 0
  @State private var total = 0
  @State private var isLoading = false
  @State private var loadError: String?
  @State private var query = ""
  @State private var isStartingChat = false

  var body: some View {
    let shown = visible
    List {
      if shown.isEmpty && isLoading {
        ForEach(0..<6, id: \.self) { _ in
          RowPlaceholder()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      } else if shown.isEmpty {
        EmptyStateView(
          symbol: query.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass",
          title: query.isEmpty ? (loadError == nil ? "No chats yet" : "Can't load chats") : "No matches",
          text: loadError ?? (query.isEmpty ? "Start one with \(title)." : "Try a different search."))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      } else {
        ForEach(shown) { session in
          let fresh = app.row(session.id) ?? session
          let isSelected = app.usesSplitLayout && app.selectedStoredID == session.id
          Button {
            app.open(fresh)
          } label: {
            SessionRow(session: fresh, isSelected: isSelected, showsBot: false)
          }
          .buttonStyle(RowButtonStyle())
          .listRowInsets(EdgeInsets())
          .listRowBackground(isSelected ? palette.threadSelected : Color.clear)
          .listRowSeparator(.hidden, edges: .top)
          .listRowSeparatorTint(palette.border)
          .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.screenPadding }
          .modifier(SessionSwipeActions(session: fresh))
          .accessibilityIdentifier("agent.session")
        }
        if fetched < total && query.isEmpty {
          HStack {
            Spacer()
            if isLoading {
              ProgressView()
            } else {
              Button("Load more") { Task { await loadPage() } }
                .font(AppFont.labelMedium)
                .foregroundStyle(palette.primaryText)
            }
            Spacer()
          }
          .padding(.vertical, 14)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .onAppear { Task { await loadPage() } }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .screenBackground()
    .environment(\.defaultMinListRowHeight, 10)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(
      text: $query, placement: app.showsSideDock ? .navigationBarDrawer(displayMode: .always) : .automatic,
      prompt: "Search \(title)'s sessions")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          isStartingChat = true
          Task {
            await app.startChat(profile: profile)
            isStartingChat = false
          }
        } label: {
          if isStartingChat { ProgressView() } else { Image(systemName: "square.and.pencil") }
        }
        .disabled(isStartingChat)
        .accessibilityLabel("New chat with \(title)")
      }
    }
    .refreshable { await reload() }
    .task(id: profile) {
      rows = app.sessions.filter { $0.profile == profile }
      await reload()
    }
  }

  private var title: String { app.title(forProfile: profile) }

  /// One row per conversation (versions folded), pinned first, then newest.
  private var visible: [SessionSummary] {
    let families = SessionGrouping.families(rows)
    return SessionGrouping.sorted(SessionGrouping.collapse(rows, families: families)).filter { $0.matches(query) }
  }

  private func reload() async {
    fetched = 0
    await loadPage()
  }

  private func loadPage() async {
    guard let client = app.client, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await client.sessionPage(profile: profile, offset: fetched)
      var merged = rows
      for row in page.rows {
        if let index = merged.firstIndex(where: { $0.id == row.id }) { merged[index] = row } else { merged.append(row) }
      }
      rows = merged
      fetched += page.rows.count
      total = page.rows.isEmpty ? fetched : page.total
      loadError = nil
    } catch {
      loadError = error.localizedDescription
      total = fetched
    }
  }
}

/// Pin, unread and archive on a chat row.
struct SessionSwipeActions: ViewModifier {
  let session: SessionSummary
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    content
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
}
