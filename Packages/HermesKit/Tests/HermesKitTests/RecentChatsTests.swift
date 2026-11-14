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

  @Test func aChatMadeHereStaysOffTheIconUntilItIsSaved() {
    let recent = three.opened(profile: "ada", storedID: "n", title: "", botTitle: "Ada", saved: false)
    #expect(recent.entries.map(\.storedID) == ["n", "c", "b", "a"])
    #expect(recent.shown.map(\.storedID) == ["c", "b", "a"])
    #expect(recent.quickActions(newChat: nil).count == 3)
    let saved = recent.saving("n", title: "Hello")
    #expect(saved.shown.map(\.storedID) == ["n", "c", "b"])
    #expect(saved.shown.first?.title == "Hello")
    // Reopening a saved chat never makes it unsaved again.
    #expect(saved.opened(profile: "ada", storedID: "n", title: "", botTitle: "", saved: false).shown.first?.storedID == "n")
  }

  @Test func aSendFinishingAfterOtherChatsOpenedKeepsTheOpeningOrder() {
    // A send started in "a", then "b", "c" and "d" were opened before it landed.
    let later = three.opened(profile: "ada", storedID: "d", title: "Fourth", botTitle: "Ada")
    #expect(later.saving("a", title: "First").shown.map(\.storedID) == ["d", "c", "b"])
    // Still in the list: it keeps its place and takes the title.
    #expect(three.saving("a", title: "First, longer").shown.map(\.storedID) == ["c", "b", "a"])
    #expect(three.saving("a", title: "First, longer").shown.last?.title == "First, longer")
    // A new chat made here, then "b" opened before its first message landed: it lands behind "b".
    let made = three.opened(profile: "ada", storedID: "n", title: "", botTitle: "Ada", saved: false)
      .opened(profile: "default", storedID: "b", title: "Second", botTitle: "Hermes")
    #expect(made.saving("n", title: "Hello").shown.map(\.storedID) == ["b", "n", "c"])
  }

  @Test func aSendFinishingAfterArchivingHereDoesNotBringTheChatBack() {
    #expect(three.removing("a").saving("a", title: "First").shown.map(\.storedID) == ["c", "b"])
    let made = three.opened(profile: "ada", storedID: "n", title: "", botTitle: "Ada", saved: false)
    #expect(made.removing("n").saving("n", title: "Hello").shown.map(\.storedID) == ["c", "b", "a"])
  }

  @Test func chatsMadeHereNeverCrowdOutSavedOnes() {
    var recent = three
    for id in ["n1", "n2", "n3", "n4"] {
      recent = recent.opened(profile: "ada", storedID: id, title: "", botTitle: "Ada", saved: false)
    }
    #expect(recent.entries.map(\.storedID) == ["n4", "n3", "n2", "c", "b", "a"])
    #expect(recent.shown.map(\.storedID) == ["c", "b", "a"])
  }

  /// The inbox read is a window (200 of a bot's 400 chats, say): a recent chat it leaves out is read
  /// on its own. Archived or deleted on the Mac drops out; an older chat stays; a failed read keeps it.
  @Test func chatsAPartialListLeavesOutAreReadOneByOne() async {
    let window = (0..<200).map { row("other-\($0)", title: "Other \($0)") }
    let refreshed = three.refreshingTitles(from: window)
    #expect(refreshed == three)
    let unlisted = refreshed.unlisted(in: window)
    #expect(unlisted.map(\.storedID) == ["c", "b", "a"])
    let lookups = await RecentChats.lookUp(unlisted) { entry in
      switch entry.storedID {
      case "c": return SessionSummary(
          json: .object(["id": .string("c"), "profile": .string("ada"), "title": .string("Third"), "archived": .number(1)]))
      case "b": return SessionSummary(
          json: .object(["id": .string("b"), "profile": .string("default"), "title": .string("Second, renamed")]))
      default: throw HermesError.http(status: 404, message: "Session not found")
      }
    }
    #expect(lookups["a"] == .gone)
    let recent = refreshed.reconciling(lookups)
    #expect(recent.entries.map(\.storedID) == ["b"])
    #expect(recent.entries.first?.title == "Second, renamed")
  }

  @Test func aFailedReadKeepsTheChat() async {
    let lookups = await RecentChats.lookUp(three.entries) { entry in
      switch entry.storedID {
      case "c": throw HermesError.timedOut("The request")
      case "b": throw HermesError.http(status: 503, message: "Session store is corrupt")
      default: throw HermesError.loginRequired
      }
    }
    #expect(Set(lookups.values) == [.unknown])
    #expect(three.reconciling(lookups) == three)
  }

  @Test func readsThatFinishLateDoNotBringBackARemovedChat() {
    let row = SessionSummary(json: .object(["id": .string("b"), "profile": .string("default"), "title": .string("Second")]))
    #expect(three.removing("b").reconciling(["b": .found(row)]).entries.map(\.storedID) == ["c", "a"])
  }

  @Test func unsavedChatsAreNeverReadOnTheirOwn() {
    let recent = three.opened(profile: "ada", storedID: "n", title: "", botTitle: "Ada", saved: false)
    #expect(recent.unlisted(in: [row("c", title: "Third")]).map(\.storedID) == ["b", "a"])
  }

  @Test func itSurvivesARoundTripThroughJSON() throws {
    let recent = three.opened(profile: "ada", storedID: "n", title: "", botTitle: "Ada", saved: false)
    let data = try JSONEncoder().encode(recent)
    #expect(try JSONDecoder().decode(RecentChats.self, from: data) == recent)
    // Saved before entries carried `saved`: every one of them was saved.
    let older = Data(#"{"entries":[{"profile":"ada","storedID":"a","title":"First","botTitle":"Ada"}]}"#.utf8)
    #expect(try JSONDecoder().decode(RecentChats.self, from: older).shown.map(\.storedID) == ["a"])
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
