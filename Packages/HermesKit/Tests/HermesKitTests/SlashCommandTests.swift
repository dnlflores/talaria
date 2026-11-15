import Foundation
import Testing

@testable import HermesKit

/// Calls a slash command makes, answered from a script; records what was asked.
private final class FakeGateway: @unchecked Sendable {
  var execAnswer: Result<JSONValue, HermesError> = .failure(.rpc(code: 5030, message: "no exec answer", reason: nil))
  var dispatchAnswer: Result<JSONValue, HermesError> = .failure(.rpc(code: 4018, message: "not a quick/plugin/bundle/skill command: x", reason: nil))
  /// Per command name, overriding `execAnswer` (for aliases).
  var execByName: [String: JSONValue] = [:]
  var execs: [String] = []
  var dispatches: [(name: String, arg: String)] = []

  func run(_ typed: String) async -> SlashResult {
    guard let invocation = SlashInvocation(typed) else { fatalError("not a command: \(typed)") }
    return await SlashRunner.run(
      invocation,
      exec: { command in
        self.execs.append(command)
        let name = command.split(separator: " ").first.map(String.init) ?? ""
        if let answer = self.execByName[name] { return answer }
        return try self.execAnswer.get()
      },
      dispatch: { name, arg in
        self.dispatches.append((name, arg))
        return try self.dispatchAnswer.get()
      })
  }
}

private let workScaffold = """
  [IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions. \
  The full skill content is loaded below.]

  # Work skill body

  The user has provided the following instruction alongside the skill invocation: fix the leak

  [Runtime note: loaded]
  """

struct SlashCommandTests {
  // MARK: What counts as a command

  @Test func commandsAndProse() throws {
    let work = try #require(SlashInvocation("  /Work fix   the leak\nand more  "))
    #expect(work.name == "work")
    #expect(work.arg == "fix   the leak\nand more")
    #expect(work.typed == "/Work fix   the leak\nand more")
    #expect(work.command == "Work fix   the leak\nand more")
    #expect(SlashInvocation("/usage")?.arg == "")
    #expect(SlashInvocation("/usr/local is full") == nil)
    #expect(SlashInvocation("run /clean") == nil)
    #expect(SlashInvocation("//comment") == nil)
    #expect(SlashInvocation("plain words") == nil)
    #expect(SlashInvocation("/")?.name == "")
    #expect(SlashInvocation("/ words")?.name == "")
  }

  @Test func theMenuShowsForOneSlashWord() {
    #expect(SlashMenu.query(in: "/") == "/")
    #expect(SlashMenu.query(in: "/wo") == "/wo")
    #expect(SlashMenu.query(in: "/work ") == nil)
    #expect(SlashMenu.query(in: "/work fix") == nil)
    #expect(SlashMenu.query(in: " /wo") == nil)
    #expect(SlashMenu.query(in: "wo") == nil)
    #expect(SlashMenu.query(in: "") == nil)
    #expect(SlashMenu.query(in: "/usr/lo") == nil)
    let work = SlashCompletion(name: "/work", summary: "", kind: .skill)
    #expect(SlashMenu.picking(work) == "/work ")
    #expect(SlashMenu.query(in: SlashMenu.picking(work)) == nil)
  }

  // MARK: complete.slash

  @Test func completionsTellSkillsFromCommands() throws {
    let answer = try JSONValue.parse("""
      {"replace_from": 1, "items": [
        {"text": "work", "display": "/work", "meta": "⚡ Pick up a task and see it through", "kind": "skill"},
        {"text": "workdash ", "display": "/workdash", "meta": "▣ Dashboards (3 skills)\\nsecond line", "kind": "skill"},
        {"text": "usage", "display": "/usage", "meta": "Show token usage", "kind": "command"},
        {"text": "/tools", "display": "/tools", "meta": "🔌 Plugin tools"},
        {"text": "skin", "display": "/skin", "meta": "Change the theme", "kind": "command"},
        {"text": "new", "display": "/new", "meta": "Start a new chat", "kind": "command"},
        {"text": "work", "display": "/work", "meta": "duplicate", "kind": "skill"},
        {"text": "review", "display": "/review", "meta": "⚡ Review a diff"}
      ]}
      """)
    let items = SlashCompletion.items(from: answer)
    #expect(items.map(\.name) == ["/work", "/workdash", "/usage", "/tools", "/review"])
    #expect(items.map(\.kind) == [.skill, .skill, .command, .command, .skill])
    #expect(items[0].summary == "Pick up a task and see it through")
    #expect(items[1].summary == "Dashboards (3 skills)")
    #expect(items[3].summary == "Plugin tools")
  }

  @Test func argumentCompletionsAreNotOffered() throws {
    let answer = try JSONValue.parse("""
      {"replace_from": 13, "items": [{"text": "alice", "display": "alice", "meta": "a persona"}]}
      """)
    #expect(SlashCompletion.items(from: answer).isEmpty)
    #expect(SlashCompletion.items(from: try JSONValue.parse(#"{"items": []}"#)).isEmpty)
  }

  @Test func desktopOwnedCommandsStayOnTheMac() {
    for name in ["/skin", "/new", "/model", "/resume", "/title", "/status", "/compress", "/exit", "/voice", "skin"] {
      #expect(SlashPolicy.isMacOnly(name), "\(name)")
    }
    for name in ["/work", "/usage", "/goal", "/skills", "/undo", "/personality", "/retry"] {
      #expect(!SlashPolicy.isMacOnly(name), "\(name)")
    }
  }

  // MARK: Directives

  @Test func directivesParseLikeTheDesktop() throws {
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "exec", "output": "hi"}"#)) == .exec(output: "hi"))
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "plugin"}"#)) == .exec(output: nil))
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "alias", "target": "queue"}"#)) == .alias(target: "queue"))
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "skill", "name": "work", "message": "m", "display": "/work"}"#))
      == .skill(name: "work", message: "m", display: "/work"))
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "send", "message": "m", "notice": "n"}"#))
      == .send(message: "m", display: nil, notice: "n"))
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "prefill", "message": "edit me"}"#)) == .prefill(message: "edit me", notice: nil))
    // Malformed or plain answers are not directives.
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "skill", "message": "m"}"#)) == nil)
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "send"}"#)) == nil)
    #expect(SlashDirective(try JSONValue.parse(#"{"type": "teleport"}"#)) == nil)
    #expect(SlashDirective(try JSONValue.parse(#"{"output": "plain"}"#)) == nil)
  }

  // MARK: Running a command

  @Test func aSkillLoadsAndShowsTheInvocation() async throws {
    let gateway = FakeGateway()
    gateway.execAnswer = .failure(.rpc(code: 4018, message: "skill command: use command.dispatch for /work", reason: nil))
    gateway.dispatchAnswer = .success(.object([
      "type": "skill", "name": "work", "message": .string(workScaffold), "display": "/work fix the leak",
    ]))
    let result = await gateway.run("/work fix the leak")
    #expect(result == SlashResult(.submit(message: workScaffold, display: "/work fix the leak")))
    #expect(gateway.execs == ["work fix the leak"])
    #expect(gateway.dispatches.map(\.name) == ["work"])
    #expect(gateway.dispatches.map(\.arg) == ["fix the leak"])
  }

  @Test func anOlderGatewayWithoutDisplayStillHidesTheSkillBody() async {
    let gateway = FakeGateway()
    gateway.execAnswer = .success(.object(["type": "skill", "name": "work", "message": .string(workScaffold)]))
    #expect(await gateway.run("/work fix the leak") == SlashResult(.submit(message: workScaffold, display: "/work fix the leak")))
    // Nothing to read the invocation from: what was typed.
    gateway.execAnswer = .success(["type": "skill", "name": "work", "message": "Do the work."])
    #expect(await gateway.run("/work now") == SlashResult(.submit(message: "Do the work.", display: "/work now")))
  }

  @Test func sendSubmitsItsMessageAfterItsNotice() async {
    let gateway = FakeGateway()
    gateway.execAnswer = .success(["type": "send", "message": "Ship the release notes", "notice": "⊙ Goal set"])
    // The bubble shows what was typed, not the words the command composed.
    #expect(await gateway.run("/goal Ship the release notes")
      == SlashResult(notice: "⊙ Goal set", .submit(message: "Ship the release notes", display: "/goal Ship the release notes")))
    gateway.execAnswer = .success(["type": "send", "message": "Ship notes"])
    #expect(await gateway.run("/goal   Ship notes") == SlashResult(.submit(message: "Ship notes", display: "/goal   Ship notes")))
    gateway.execAnswer = .success(["type": "send", "message": "Ship notes", "display": "/goal Ship notes"])
    #expect(await gateway.run("/g Ship notes") == SlashResult(.submit(message: "Ship notes", display: "/goal Ship notes")))
    gateway.execAnswer = .success(["type": "send", "message": "   "])
    #expect(await gateway.run("/prompt") == SlashResult(.failure("/prompt: empty message")))
  }

  @Test func prefillGoesToTheComposer() async {
    let gateway = FakeGateway()
    gateway.execAnswer = .failure(.rpc(code: 4009, message: "busy", reason: nil))
    gateway.dispatchAnswer = .success(["type": "prefill", "message": "  the last message  "])
    #expect(await gateway.run("/undo") == SlashResult(.prefill("the last message")))
  }

  @Test func plainOutputIsANotice() async {
    let gateway = FakeGateway()
    gateway.execAnswer = .success(["output": "Tokens: 12,400", "warning": "estimate"])
    #expect(await gateway.run("/usage") == SlashResult(.output("warning: estimate\nTokens: 12,400")))
    gateway.execAnswer = .success(["output": ""])
    #expect(await gateway.run("/usage") == SlashResult(.output("/usage: no output")))
    gateway.execAnswer = .success(["type": "exec", "output": "done"])
    #expect(await gateway.run("/tools list") == SlashResult(.output("done")))
    #expect(gateway.dispatches.isEmpty, "a plain answer needs no fallback")
  }

  @Test func anAliasRunsItsTarget() async {
    let gateway = FakeGateway()
    gateway.execByName["w"] = ["type": "alias", "target": "/work"]
    gateway.execByName["work"] = ["type": "skill", "name": "work", "message": "Do it.", "display": "/work now"]
    #expect(await gateway.run("/w now") == SlashResult(.submit(message: "Do it.", display: "/work now")))
    #expect(gateway.execs == ["w now", "work now"])
    // An alias to a command the phone leaves to the Mac stays there.
    gateway.execByName["n"] = ["type": "alias", "target": "new"]
    #expect(await gateway.run("/n") == SlashResult(.macOnly))
    // Aliases that loop give up.
    gateway.execByName["a"] = ["type": "alias", "target": "b"]
    gateway.execByName["b"] = ["type": "alias", "target": "a"]
    if case .failure = await gateway.run("/a").outcome {} else { Issue.record("a loop must fail") }
  }

  @Test func errorsAreNotices() async {
    let gateway = FakeGateway()
    gateway.execAnswer = .failure(.rpc(code: 5030, message: "slash worker start failed: boom", reason: nil))
    #expect(await gateway.run("/frobnicate") == SlashResult(.failure("/frobnicate failed: slash worker start failed: boom")))
    gateway.dispatchAnswer = .failure(.rpc(code: 4001, message: "no active session to undo", reason: nil))
    #expect(await gateway.run("/undo") == SlashResult(.failure("no active session to undo")))
    gateway.dispatchAnswer = .success(["type": "nonsense"])
    #expect(await gateway.run("/odd") == SlashResult(.failure("Unexpected answer from the Mac for /odd.")))
  }

  @Test func macOnlyCommandsNeverReachTheGateway() async {
    let gateway = FakeGateway()
    #expect(await gateway.run("/skin dark") == SlashResult(.macOnly))
    #expect(await gateway.run("/NEW") == SlashResult(.macOnly))
    #expect(gateway.execs.isEmpty && gateway.dispatches.isEmpty)
  }

  @Test func aBareSlashGoesBackToTheComposer() async {
    let gateway = FakeGateway()
    #expect(await gateway.run("/ hello") == SlashResult(notice: "Type a command name right after the /.", .prefill("/ hello")))
    #expect(gateway.execs.isEmpty)
  }

  /// Whatever the gateway answers, the typed command is never what goes to the model.
  @Test func aCommandNeverFallsBackToBeingSentAsWords() async throws {
    let typed = "/work fix the leak"
    let answers: [Result<JSONValue, HermesError>] = [
      .failure(.rpc(code: 5030, message: "crash", reason: nil)),
      .failure(.transport("socket closed")),
      .failure(.timedOut("slash.exec")),
      .success(.null),
      .success(["type": "skill", "name": "work"]),
      .success(["type": "skill", "name": "work", "message": ""]),
      .success(["type": "send", "message": ""]),
      .success(["type": "teleport", "message": .string(typed)]),
      .success(["type": "exec"]),
      .success(["type": "prefill", "message": ""]),
    ]
    for exec in answers {
      for dispatch in answers {
        let gateway = FakeGateway()
        gateway.execAnswer = exec
        gateway.dispatchAnswer = dispatch
        let result = await gateway.run(typed)
        if case .submit(let message, _) = result.outcome {
          #expect(message != typed, "exec \(exec), dispatch \(dispatch)")
          #expect(SlashInvocation(message) == nil, "a submitted message must not be a command again")
        }
      }
    }
    // Only a real directive submits, and then its message.
    let gateway = FakeGateway()
    gateway.execAnswer = .success(["type": "send", "message": .string(typed)])
    if case .submit = await gateway.run(typed).outcome {} else { Issue.record("a send directive submits") }
  }

  // MARK: In the transcript

  @Test func aSkillBubbleMatchesTheMacsCopy() {
    var state = ChatState()
    state.items = [.user("earlier", timestamp: 1), TranscriptItem(kind: .assistant, text: "ok")]
    var bubble = TranscriptItem.outgoing(workScaffold, shown: "/work fix the leak", timestamp: 2)
    #expect(bubble.text == "/work fix the leak")
    bubble.isPending = false
    state.items.append(bubble)
    state.items.append(.slashNotice("Tokens: 12", command: "/usage", timestamp: 3))
    // The Mac stores the expanded skill; read back, it is the same message, not a second one.
    let stored = TranscriptItem.items(fromStoredRows: [
      ["id": 1, "role": "user", "content": "earlier"], ["id": 2, "role": "assistant", "content": "ok"],
      ["id": 3, "role": "user", "content": .string(workScaffold)], ["id": 4, "role": "assistant", "content": "On it."],
    ])
    state.reconcile(fresh: stored, inflight: nil, now: 10)
    #expect(state.items.filter { $0.kind == .user }.map(\.text) == ["earlier", "/work fix the leak"])
    #expect(state.items.last?.text == "On it.")
    #expect(state.items.contains { $0.isLocal && $0.command == "/usage" }, "the notice stays on the phone")
  }

  /// A sent message is recognised in the Mac's history by what was sent, apart from what its bubble
  /// shows: a send directive's composed words with a staged file, and a skill typed through an
  /// alias whose bubble differs from the invocation the Mac's history reads back.
  @Test(arguments: [
    (sent: "Ship notes\n\n@file:/fixture/notes.txt", shown: "/goal Ship notes"),
    (sent: "Ship notes", shown: "/goal Ship notes"),
    (sent: workScaffold, shown: "/w fix the leak"),
    (sent: workScaffold + "\n\n@file:/fixture/leak.log", shown: "/work fix the leak"),
  ])
  func aSentMessageLandsAgainstItsStoredCopy(sent: String, shown: String) {
    let stored: [JSONValue] = [
      ["id": 1, "role": "user", "content": "earlier"], ["id": 2, "role": "assistant", "content": "ok"],
      ["id": 3, "role": "user", "content": .string(sent)],
    ]
    let fresh = TranscriptItem.items(fromStoredRows: stored)
    func sending() -> (ChatState, UUID) {
      var state = ChatState()
      state.items = Array(TranscriptItem.items(fromStoredRows: Array(stored.prefix(2))))
      // As `ChatModel.deliver` builds it: the bubble first, then the exact text once files are staged.
      var bubble = TranscriptItem.outgoing("Ship notes", shown: shown, timestamp: 2)
      bubble.submitted(sent)
      state.items.append(bubble)
      return (state, bubble.id)
    }
    // Accepted, acknowledgement lost: the newest page shows it landed, so it is not sent again.
    var (tail, id) = sending()
    let lined = tail.reconcileTail(fresh: fresh, inflight: .null, now: 3)
    #expect(lined)
    #expect(tail.items.first { $0.id == id }?.hasLanded == true)
    #expect(tail.items.filter { $0.kind == .user }.count == 2)
    #expect(tail.items.last?.text == shown, "the bubble keeps showing what was typed")
    // A whole reload finds it too.
    var (whole, wholeID) = sending()
    whole.reconcile(fresh: fresh, inflight: .null, now: 3)
    #expect(whole.items.first { $0.id == wholeID }?.hasLanded == true)
    #expect(whole.items.filter { $0.kind == .user }.count == 2)
    // Once sent it stays matched against the stored copy, so the next reload adds nothing.
    var settled = tail
    if let index = settled.items.firstIndex(where: { $0.id == id }) { settled.items[index].isPending = false }
    settled.reconcile(fresh: fresh, inflight: .null, now: 4)
    #expect(settled.items.filter { $0.kind == .user }.count == 2)
    #expect(settled.items.contains { $0.id == id })
  }

  @Test func storedTextIsHowTheHistoryReadsBack() {
    #expect(TranscriptItem.storedText(submitted: workScaffold) == "/work fix the leak")
    #expect(TranscriptItem.storedText(submitted: "plain words\n\n@file:a.txt") == "plain words\n\n@file:a.txt")
    let read = TranscriptItem.items(fromStoredRows: [["role": "user", "content": .string(workScaffold)]])
    #expect(read.first?.text == TranscriptItem.storedText(submitted: workScaffold))
  }
}
