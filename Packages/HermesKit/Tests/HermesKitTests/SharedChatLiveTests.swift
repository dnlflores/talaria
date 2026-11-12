import Foundation
import Testing

@testable import HermesKit

/// The phone and the desktop app on one chat. Both are viewers of the same gateway: the second
/// client here stands in for the desktop app, which dials the gateway the same way.
///
///   TALARIA_LIVE_BASE=http://127.0.0.1:4300 TALARIA_LIVE_PROFILE=<cheap bot> TALARIA_LIVE_TURN=1 \
///     swift test --filter SharedChat
///
/// Two real turns (a clarify question and a terminal command); the chat is archived at the end.
@Suite(.serialized) struct SharedChatLiveTests {
  /// Everything one client receives, readable from the test while it keeps arriving.
  actor Inbox {
    var events: [GatewayEvent] = []
    var requests: [ServerRequest] = []
    func add(_ incoming: RPCConnection.Incoming) {
      switch incoming {
      case .event(let event): events.append(event)
      case .request(let request): requests.append(request)
      case .state: break
      }
    }
    func count(_ type: String, in session: String, since: Int = 0) -> Int {
      events.dropFirst(since).filter { $0.type == type && $0.sessionID == session }.count
    }
    var size: Int { events.count }
  }

  private func connect() async throws -> (HermesClient, Inbox, Task<Void, Never>) {
    let client = try Live.client()
    let inbox = Inbox()
    let pump = Task { for await incoming in client.rpc.incoming { await inbox.add(incoming) } }
    await client.rpc.start()
    try await client.rpc.waitUntilReady(timeout: 30)
    return (client, inbox, pump)
  }

  private func wait(_ seconds: Double, until check: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await check() { return true }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  @Test(.enabled(if: Live.turnEnabled), .timeLimit(.minutes(5)))
  func aTurnFromEitherSideReachesTheOther() async throws {
    let (phone, phoneInbox, phonePump) = try await connect()
    let (desk, deskInbox, deskPump) = try await connect()
    defer {
      phonePump.cancel()
      deskPump.cancel()
    }
    let profile = Live.profile
    let chat = try await phone.create(profile: profile)
    let sid = chat.liveID
    // The desktop has the chat open before the phone talks in it.
    let opened = try await desk.resume(storedID: chat.storedID, profile: profile, omitMessages: true)
    #expect(opened.liveID == sid)

    try await phone.submit(
      liveID: sid, profile: profile,
      text: "Use the clarify tool to ask me exactly 'Pick one' with choices Red and Blue. After I answer, "
        + "run `echo picked` with your terminal tool, then reply with my pick only.")

    // The question reaches the desktop (and the phone), and the desktop answers it.
    let asked = await wait(90) { await deskInbox.requests.contains { $0.method == "clarify" && $0.sessionID == sid } }
    #expect(asked, "the desktop never saw the phone's question")
    let phoneAsked = await phoneInbox.requests.contains { $0.method == "clarify" && $0.sessionID == sid }
    #expect(phoneAsked)
    if asked, let question = await deskInbox.requests.first(where: { $0.method == "clarify" }) {
      #expect(question.isPrompt)
      await desk.answer(question, result: ["answers": [question.params["prompt_id"].stringValue: "Blue"]], profile: profile)
    }
    // The phone hears that it was answered elsewhere, so its card stops waiting.
    let settled = await wait(30) { await phoneInbox.count("prompt.settled", in: sid) > 0 }
    #expect(settled)

    let finished = await wait(120) { await deskInbox.count("message.complete", in: sid) > 0 }
    #expect(finished, "the desktop never saw the phone's turn end")
    #expect(await deskInbox.count("thinking.delta", in: sid) + deskInbox.count("reasoning.delta", in: sid) > 0)
    #expect(await deskInbox.count("tool.complete", in: sid) >= 2)
    #expect(await phoneInbox.count("message.complete", in: sid) == 1)

    // The desktop takes the next turn; the phone sees it live.
    let mark = await phoneInbox.size
    try await desk.submit(liveID: sid, profile: profile, text: "Run `echo again` with your terminal tool, then reply done.")
    let deskTurn = await wait(120) { await phoneInbox.count("message.complete", in: sid, since: mark) > 0 }
    #expect(deskTurn, "the phone never saw the desktop's turn")
    #expect(await phoneInbox.count("tool.complete", in: sid, since: mark) >= 1)

    // Settings changed on one side are fenced and land; the other side is told.
    let mark2 = await deskInbox.size
    // Titles are unique per bot, archived chats included.
    try await phone.setTitle(liveID: sid, profile: profile, title: "Shared chat live test \(UUID().uuidString.prefix(8))")
    let renamed = await wait(15) { await deskInbox.count("session.updated", in: sid, since: mark2) > 0 }
    #expect(renamed)

    try await phone.setArchived(storedID: chat.storedID, profile: profile, archived: true)
    await phone.rpc.stop()
    await desk.rpc.stop()
  }

  @Test(.enabled(if: Live.turnEnabled), .timeLimit(.minutes(3)))
  func aReplyRunningWhenTheChatOpensIsCaughtUpAndStoppable() async throws {
    let (phone, _, phonePump) = try await connect()
    let (desk, deskInbox, deskPump) = try await connect()
    defer {
      phonePump.cancel()
      deskPump.cancel()
    }
    let profile = Live.profile
    let chat = try await desk.create(profile: profile)
    let sid = chat.liveID
    try await desk.submit(
      liveID: sid, profile: profile,
      text: "First say 'starting now' in one short sentence, then run `sleep 25; echo slept` with your terminal tool, then reply done.")
    let toolRunning = await wait(60) { await deskInbox.count("tool.start", in: sid) > 0 }
    #expect(toolRunning)

    // The phone opens it mid-turn: no refusal, the turn shows as running, and its text so far comes along.
    let opened = try await phone.resume(storedID: chat.storedID, profile: profile, omitMessages: true)
    #expect(opened.isRunning)
    #expect(opened.inflight["streaming"] == true)

    // The phone stops the desktop's reply.
    try await phone.interrupt(liveID: sid, profile: profile)
    let ended = await wait(30) { await deskInbox.count("message.complete", in: sid) > 0 }
    #expect(ended, "the interrupt from the phone did not end the desktop's turn")

    try await desk.setArchived(storedID: chat.storedID, profile: profile, archived: true)
    await phone.rpc.stop()
    await desk.rpc.stop()
  }
}
