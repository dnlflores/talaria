import Foundation
import Testing

@testable import HermesKit

/// The app icon's quick actions: the last chats opened on the phone, and how the icon carries them.
struct RecentChatsTests {
  private func row(_ id: String, title: String, archived: Bool = false) -> SessionSummary {
    SessionSummary(
      json: .object(["id": .string(id), "profile": .string("ada"), "title": .string(title), "archived": .bool(archived)]))
  }

  private var three: RecentChats {
    RecentChats()
      .opened(profile: "ada", storedID: "a", title: "First", botTitle: "Ada")
      .opened(profile: "default", storedID: "b", title: "Second", botTitle: "Hermes")
      .opened(profile: "ada", storedID: "c", title: "Third", botTitle: "Ada")
  }

  @Test func theNewestOpenedComesFirst() {
    #expect(three.entries.map(\.storedID) == ["c", "b", "a"])
  }

  @Test func reopeningMovesAChatToTheFrontOnce() {
    let recent = three.opened(profile: "ada", storedID: "a", title: "First", botTitle: "Ada")
    #expect(recent.entries.map(\.storedID) == ["a", "c", "b"])
  }

  @Test func onlyThreeAreKept() {
    let recent = three.opened(profile: "ada", storedID: "d", title: "Fourth", botTitle: "Ada")
    #expect(recent.entries.map(\.storedID) == ["d", "c", "b"])
    #expect(RecentChats(entries: recent.entries + three.entries).entries.count == 3)
  }

  @Test func anEmptyTitleKeepsTheOneAlreadyKnown() {
    let recent = three.opened(profile: "ada", storedID: "b", title: "", botTitle: "")
    #expect(recent.entries.first == .init(profile: "ada", storedID: "b", title: "Second", botTitle: "Hermes"))
    let fresh = RecentChats().opened(profile: "ada", storedID: "z", title: "", botTitle: "Ada")
    #expect(fresh.entries.first?.displayTitle == "Untitled chat")
  }

  @Test func archivingHereRemovesTheChat() {
    #expect(three.removing("b").entries.map(\.storedID) == ["c", "a"])
    #expect(three.removing("nope") == three)
  }

  @Test func aListReadRefreshesTitlesAndDropsArchivedChats() {
    let rows = [row("a", title: "First, renamed #2"), row("b", title: "Second", archived: true)]
    let recent = three.refreshingTitles(from: rows, botTitles: ["ada": "Ada Lovelace"])
    // "c" is not in this read (the list is a window): it stays as it was, with the new bot name.
    #expect(recent.entries.map(\.storedID) == ["c", "a"])
    #expect(recent.entries.map(\.title) == ["Third", "First, renamed"])
    #expect(recent.entries.map(\.botTitle) == ["Ada Lovelace", "Ada Lovelace"])
  }

  @Test func aChatMissingFromAReadWithAllItsBotsChatsDropsOut() {
    // "ada" has two chats on the Mac and both are in this read, so "c" was archived or deleted there.
    // "default" has more chats than the read holds: "b" may just be older, and stays.
    let rows = [row("a", title: "First"), row("x", title: "Other")]
    let recent = three.refreshingTitles(from: rows, totals: ["ada": 2, "default": 40])
    #expect(recent.entries.map(\.storedID) == ["b", "a"])
    #expect(three.refreshingTitles(from: rows).entries.map(\.storedID) == ["c", "b", "a"])
  }

  @Test func itSurvivesARoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(three)
    #expect(try JSONDecoder().decode(RecentChats.self, from: data) == three)
  }

  @Test func theIconOffersANewChatThenTheRecentChats() {
    let items = three.quickActions(newChat: (profile: "ada", botTitle: "Ada"))
    #expect(items.map(\.title) == ["New chat", "Third", "Second", "First"])
    #expect(items.map(\.subtitle) == ["Ada", "Ada", "Hermes", "Ada"])
    #expect(items.map(\.symbol) == ["square.and.pencil", "bubble.left", "bubble.left", "bubble.left"])
    #expect(items.first?.action == .newChat(profile: "ada"))
    #expect(items[1].action == .chat(profile: "ada", storedID: "c"))
    #expect(RecentChats().quickActions(newChat: nil).isEmpty)
  }

  @Test func anActionComesBackFromItsTypeAndUserInfo() {
    for action in [QuickAction.newChat(profile: "ada"), .chat(profile: "default", storedID: "local-1")] {
      let type = action.type(bundleID: "app.talaria.Talaria")
      #expect(QuickAction(type: type, userInfo: action.userInfo) == action)
    }
    #expect(QuickAction.newChat(profile: "ada").type(bundleID: "x") == "x.newchat")
    #expect(QuickAction.chat(profile: "ada", storedID: "1").type(bundleID: "x") == "x.chat")
    #expect(QuickAction(type: "x.chat", userInfo: ["profile": "ada"]) == nil)
    #expect(QuickAction(type: "x.newchat", userInfo: nil) == nil)
    #expect(QuickAction(type: "x.other", userInfo: ["profile": "ada", "storedID": "1"]) == nil)
  }
}
