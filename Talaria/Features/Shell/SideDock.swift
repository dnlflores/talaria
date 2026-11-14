import SwiftUI

extension View {
  /// The side dock floating at the left edge, in a strip of its own beside the screen. A safe area
  /// inset would be simpler, but the split view lays its columns out over one.
  @ViewBuilder
  func sideDock(_ isOn: Bool, isSplit: Bool) -> some View {
    if isOn {
      HStack(spacing: 0) {
        SideDock(isSplit: isSplit)
          .frame(width: SideDock.room, alignment: .leading)
          .frame(maxHeight: .infinity)
          .screenBackground()
        self
      }
    } else {
      self
    }
  }
}

/// The side dock (iPad, an unfolded iPhone Duo): the areas stacked in one tall pill of glass on
/// the left, like Instagram's on iPad. The picked area sits on a soft pill with a filled symbol;
/// New chat and Settings close the column.
struct SideDock: View {
  /// The dock's width.
  static let width: CGFloat = 68
  /// The width the screen leaves free for it: the dock and its margin on both sides.
  static let room: CGFloat = width + 2 * margin
  private static let margin: CGFloat = 10

  /// Areas switch the split view's columns, rather than the stack's first page.
  let isSplit: Bool
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var showsBotPicker = false
  @State private var isStartingChat = false

  var body: some View {
    VStack(spacing: 6) {
      area(.chats, symbol: "message", selectedSymbol: "message.fill")
      area(.bots, symbol: "circle.grid.cross", selectedSymbol: "circle.grid.cross.fill")
      area(.kanban, symbol: "rectangle.split.3x1", selectedSymbol: "rectangle.split.3x1.fill")
      newChatButton
      area(.settings, symbol: "gearshape", selectedSymbol: "gearshape.fill")
    }
    .padding(.vertical, 8)
    .frame(width: Self.width)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.leading, Self.margin)
    .sheet(isPresented: $showsBotPicker) {
      BotPickerSheet { profile in start(profile) }
        .presentationDetents([.medium, .large])
    }
  }

  // MARK: Items

  private func area(_ tab: AppTab, symbol: String, selectedSymbol: String) -> some View {
    let isOn = selected == tab
    return Button {
      open(tab)
    } label: {
      Image(systemName: isOn ? selectedSymbol : symbol)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(palette.foreground)
        .frame(width: 54, height: 50)
        .background(isOn ? palette.foreground.opacity(0.09) : Color.clear, in: Capsule())
        .overlay(alignment: .topTrailing) { badge(for: tab) }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityValue(tab == .chats && !app.waitingOnYou.isEmpty ? "\(app.waitingOnYou.count) need you" : "")
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifier("area.\(tab.title.lowercased())")
  }

  private var newChatButton: some View {
    Button(action: newChat) {
      Group {
        if isStartingChat {
          ProgressView()
        } else {
          Image(systemName: "plus").font(.system(size: 24, weight: .regular))
        }
      }
      .foregroundStyle(palette.foreground)
      .frame(width: 54, height: 50)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isStartingChat)
    .accessibilityLabel("New chat")
    .accessibilityIdentifier("area.new")
  }

  /// A red count on Chats when chats there wait on an answer from you.
  @ViewBuilder
  private func badge(for tab: AppTab) -> some View {
    if tab == .chats, !app.waitingOnYou.isEmpty {
      Text("\(app.waitingOnYou.count)")
        .font(AppFont.sans(12, .bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(minWidth: 21, minHeight: 21)
        .background(Color(red: 0.93, green: 0.2, blue: 0.25), in: Capsule())
        .offset(x: 2, y: 2)
        .accessibilityHidden(true)
    }
  }

  // MARK: Where you are

  /// The area marked as open. In one stack Kanban and Settings are pages on the Chats stack, so
  /// the stack's first page says which is open.
  private var selected: AppTab? {
    if isSplit { return app.tab == .cron ? nil : app.tab }
    if app.tab == .bots { return .bots }
    switch app.path.first {
    case .kanban: return .kanban
    case .settings: return .settings
    case .cron: return nil
    default: return .chats
    }
  }

  private func open(_ tab: AppTab) {
    let isOn = selected == tab
    if !isOn { UISelectionFeedbackGenerator().selectionChanged() }
    if isSplit {
      // Chats again: from a bot's full list back to the inbox.
      if isOn, tab == .chats { app.splitAgent = nil }
      app.tab = tab
      return
    }
    switch tab {
    case .bots:
      if isOn { app.hubPath = [] } else { app.tab = .bots }
    case .chats:
      // Back to the inbox when already there, or when Kanban or Settings covers it.
      if isOn || [Route.kanban, .settings, .cron].contains(where: { $0 == app.path.first }) {
        app.path = []
      }
      app.tab = .chats
    default:
      guard let route = Route.area(tab) else { return }
      app.tab = .chats
      app.path = [route]
    }
  }

  // MARK: New chat

  /// In Agents, a chat with the bot on screen; elsewhere with the one picked (or the only one).
  private func newChat() {
    if app.tab == .bots {
      start(isSplit ? (app.areas.bot ?? app.currentHubProfile) : app.currentHubProfile)
    } else if app.profiles.count <= 1 {
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
