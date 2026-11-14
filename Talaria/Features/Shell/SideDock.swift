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

/// The side dock (iPad, an unfolded iPhone Duo): Chats and Agents stacked in one pill of glass on
/// the left, like Instagram's on iPad. The picked area sits on a soft pill with a filled symbol.
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

  var body: some View {
    VStack(spacing: 6) {
      area(.chats, symbol: "message", selectedSymbol: "message.fill")
      area(.bots, symbol: "circle.grid.cross", selectedSymbol: "circle.grid.cross.fill")
    }
    .padding(.vertical, 8)
    .frame(width: Self.width)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.leading, Self.margin)
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

  /// The area marked as open. Kanban, Cron and Settings have no item: in one stack they are pages
  /// on Chats (or Agents), and in the split view nothing is marked while one fills the list.
  private var selected: AppTab? {
    if isSplit { return [.chats, .bots].contains(app.tab) ? app.tab : nil }
    return app.tab == .bots ? .bots : .chats
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
    // The area already open: back to its first screen.
    if isOn {
      if tab == .bots { app.hubPath = [] } else { app.path = [] }
    }
    app.tab = tab
  }
}
