import HermesKit
import Observation
import SwiftUI

/// What each area has open, shared by both shells so a resize on iPad keeps your place.
@MainActor @Observable
final class AreaState {
  var bot: String?
  var cronJob: String?
  var kanbanCard: String?
  let cron = CronModel()
  let kanban = KanbanModel()
}

/// The app's shell: a tab bar on iPhone, a sidebar with the areas on iPad.
struct MainShell: View {
  @Environment(AppModel.self) private var app
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      if sizeClass == .regular {
        SidebarShell()
      } else {
        TabShell()
      }
    }
    .onAppear { app.usesSplitLayout = sizeClass == .regular }
    .onChange(of: sizeClass) { _, size in
      app.usesSplitLayout = size == .regular
      if size != .regular {
        // Kanban and Settings have no tab on iPhone: they open on the Chats stack.
        if app.tab == .kanban || app.tab == .settings {
          let route: Route = app.tab == .kanban ? .kanban : .settings
          app.tab = .chats
          app.path = [route]
        } else if app.path.count > 1, let last = app.path.last {
          // Leaving the split keeps only the chat on screen, so back still lands on the inbox.
          app.path = [last]
        }
      } else if let last = app.path.last {
        switch last {
        case .kanban: app.tab = .kanban; app.path = []
        case .settings: app.tab = .settings; app.path = []
        case .agent(let profile): app.splitAgent = profile; app.path = []
        case .chat: break
        }
      }
    }
  }
}

// MARK: - iPhone

private struct TabShell: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    @Bindable var areas = app.areas
    TabView(selection: $app.tab) {
      Tab(AppTab.chats.title, systemImage: AppTab.chats.symbol, value: AppTab.chats) {
        NavigationStack(path: $app.path) {
          HomeView()
            .navigationDestination(for: Route.self) { route in
              switch route {
              case .chat(let profile, let storedID):
                ChatRouteView(profile: profile, storedID: storedID)
                  .id(storedID)
              case .agent(let profile):
                AgentSessionsView(profile: profile)
              case .kanban:
                KanbanBoardView(model: areas.kanban, selection: $areas.kanbanCard)
                  .navigationDestination(item: $areas.kanbanCard) { id in
                    KanbanTaskView(model: areas.kanban, taskID: id, select: { areas.kanbanCard = $0 })
                  }
              case .settings:
                SettingsView()
              }
            }
        }
      }
      Tab(AppTab.bots.title, systemImage: AppTab.bots.symbol, value: AppTab.bots) {
        NavigationStack {
          BotsList(selection: $areas.bot)
            .navigationDestination(item: $areas.bot) { name in BotDetailView(name: name) }
        }
      }
      Tab(AppTab.cron.title, systemImage: AppTab.cron.symbol, value: AppTab.cron) {
        NavigationStack {
          CronList(model: areas.cron, selection: $areas.cronJob)
            .navigationDestination(item: $areas.cronJob) { id in CronDetailView(model: areas.cron, jobID: id) }
        }
      }
    }
  }
}

// MARK: - iPad

/// Areas on the left, the area's list in the middle, what is open on the right, like Mail.
private struct SidebarShell: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var columns: NavigationSplitViewVisibility = .all

  var body: some View {
    @Bindable var app = app
    @Bindable var areas = app.areas
    NavigationSplitView(columnVisibility: $columns) {
      AreaSidebar()
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    } content: {
      Group {
        switch app.tab {
        case .chats:
          // A bot's full list replaces the inbox in this column; the chat picked from it opens on
          // the right. A stack nested in the column made the split view hide the areas column.
          if let profile = app.splitAgent {
            AgentSessionsView(profile: profile)
              .id(profile)
              .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                  Button {
                    app.splitAgent = nil
                  } label: {
                    Image(systemName: "chevron.left")
                  }
                  .accessibilityLabel("Chats")
                  .accessibilityIdentifier("BackButton")
                }
              }
          } else {
            HomeView()
          }
        case .bots: BotsList(selection: $areas.bot)
        case .kanban: KanbanBoardView(model: areas.kanban, selection: $areas.kanbanCard)
        case .cron: CronList(model: areas.cron, selection: $areas.cronJob)
        case .settings: SettingsView()
        }
      }
      .navigationSplitViewColumnWidth(min: 320, ideal: 370, max: 440)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    // Swapping the list column (a bot's full list in, back to the inbox) reads to the split
    // view as navigation, and in portrait it then hides the areas column. Keep all three.
    .onChange(of: app.splitAgent) { _, _ in
      Task { @MainActor in columns = .all }
    }
  }

  @ViewBuilder
  private var detail: some View {
    let areas = app.areas
    switch app.tab {
    case .chats:
      if case .chat(let profile, let storedID)? = app.path.last {
        NavigationStack { ChatRouteView(profile: profile, storedID: storedID) }
          .id(storedID)
      } else {
        DetailPlaceholder(symbol: "bubble.left.and.text.bubble.right", title: "No chat open", text: "Pick one from the list, or start a new one.")
      }
    case .bots:
      if let bot = areas.bot {
        NavigationStack { BotDetailView(name: bot) }.id(bot)
      } else {
        DetailPlaceholder(symbol: "person.2", title: "No bot open", text: "Pick a bot to see its page.")
      }
    case .kanban:
      if let card = areas.kanbanCard {
        NavigationStack { KanbanTaskView(model: areas.kanban, taskID: card, select: { areas.kanbanCard = $0 }) }.id(card)
      } else {
        DetailPlaceholder(symbol: "rectangle.split.3x1", title: "No card open", text: "Pick a card to read its brief and runs.")
      }
    case .cron:
      if let job = areas.cronJob {
        NavigationStack { CronDetailView(model: areas.cron, jobID: job) }.id(job)
      } else {
        DetailPlaceholder(symbol: "clock", title: "No job open", text: "Pick a job to see its schedule and runs.")
      }
    case .settings:
      VStack(spacing: 8) {
        Wordmark(size: 30)
        Text("Hermes on your Mac, wherever you are.")
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.screen.ignoresSafeArea())
    }
  }
}

/// The left column on iPad: the wordmark and one row per area.
private struct AreaSidebar: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    List {
      ForEach(AppTab.allCases) { tab in
        let isSelected = app.tab == tab
        Button {
          app.tab = tab
        } label: {
          HStack(spacing: 12) {
            Image(systemName: tab.symbol)
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(isSelected ? palette.primaryText : palette.icon)
              .frame(width: 22)
            Text(tab.title)
              .font(isSelected ? AppFont.bodySemibold : AppFont.body)
              .foregroundStyle(isSelected ? palette.threadSelectedForeground : palette.foreground)
            Spacer(minLength: 4)
            badge(for: tab)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(isSelected ? palette.threadSelected : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("area.\(tab.rawValue)")
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.screen.ignoresSafeArea())
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        HStack(spacing: 8) {
          Wordmark()
          if let tag = ConnectionTag.current(app.connection) { TagLabel(text: tag.text, tint: tag.tint(palette)) }
        }
        .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)
    }
    .navigationBarTitleDisplayMode(.inline)
  }

  /// A count next to Chats when something there needs an answer.
  @ViewBuilder
  private func badge(for tab: AppTab) -> some View {
    if tab == .chats, !app.waitingOnYou.isEmpty {
      Text("\(app.waitingOnYou.count)")
        .font(AppFont.sans(11, .semibold))
        .foregroundStyle(palette.warningForeground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(palette.warning, in: Capsule())
        .accessibilityLabel("\(app.waitingOnYou.count) need you")
    }
  }
}

/// The empty right side on iPad before something is picked.
struct DetailPlaceholder: View {
  let symbol: String
  let title: String
  let text: String
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(palette.iconMuted)
      Text(title).font(AppFont.headline).foregroundStyle(palette.foreground)
      Text(text).font(AppFont.footnote).foregroundStyle(palette.foregroundMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.screen.ignoresSafeArea())
  }
}

/// The connection state as a tag next to the wordmark, or nothing when connected.
enum ConnectionTag {
  case connecting, offline, signedOut

  static func current(_ state: ConnectionState) -> ConnectionTag? {
    switch state {
    case .open: return nil
    case .connecting, .idle: return .connecting
    case .closed: return .offline
    case .unauthorized: return .signedOut
    }
  }

  var text: String {
    switch self {
    case .connecting: return "Connecting"
    case .offline: return "Offline"
    case .signedOut: return "Signed out"
    }
  }

  func tint(_ palette: Palette) -> Color? {
    switch self {
    case .connecting: return nil
    case .offline: return palette.warningForeground
    case .signedOut: return palette.dangerForeground
    }
  }
}
