import Foundation
import Testing

@testable import HermesKit

/// The gateway's shapes, as the desktop app's gateway sends them (recorded Nov 2026), mapped onto
/// what the app already takes.
@Suite struct GatewayWireTests {
  @Test func aClarifyEventBecomesAQuestionCard() throws {
    let request = try #require(ServerRequest.prompt(kind: "clarify", sessionID: "local-1", payload: [
      "kind": "clarify", "prompt_id": "ef97f88837", "execution_generation": 3, "question": "Pick one",
      "choices": ["Red", "Blue"],
    ]))
    #expect(request.method == "clarify")
    #expect(request.isPrompt)
    #expect(request.sessionID == "local-1")
    #expect(request.id == ServerRequest.promptRequestID(kind: "clarify", promptID: "ef97f88837"))
    let questions = ClarifyQuestion.list(from: request.params["questions"])
    #expect(questions == [ClarifyQuestion(qid: "ef97f88837", question: "Pick one", choices: ["Red", "Blue"], multiSelect: false)])
    #expect(request.params["execution_generation"] == 3)
  }

  @Test func anApprovalEventBecomesAnApprovalSheet() throws {
    let request = try #require(ServerRequest.prompt(kind: "approval", sessionID: "local-1", payload: [
      "kind": "approval", "prompt_id": "p2", "execution_generation": 1, "command": "rm -rf build",
      "description": "deletes a folder", "choices": ["once", "session", "always", "deny"],
    ]))
    #expect(request.method == "approval")
    #expect(request.params["command"] == "rm -rf build")
    #expect(request.params["allow_permanent"] == true)
  }

  @Test func aPromptWithoutAnIDIsIgnored() {
    #expect(ServerRequest.prompt(kind: "clarify", sessionID: "s", payload: ["question": "?"]) == nil)
    #expect(ServerRequest.prompt(kind: "sudo", sessionID: "s", payload: ["prompt_id": "x"]) == nil)
    #expect(!ServerRequest(rawID: 7, method: "sudo", params: [:]).isPrompt)
  }

  @Test func aClarifyAnswerIsTheTextTheGatewayTakes() {
    #expect(HermesClient.clarifyAnswer(["answers": ["p": "Blue"]], promptID: "p") == "Blue")
    #expect(HermesClient.clarifyAnswer(["answers": ["p": ["A", "B"]]], promptID: "p") == "A, B")
    #expect(HermesClient.clarifyAnswer(["answers": [:]], promptID: "p") == "")
  }

  @Test func aSettledQuestionLeavesTheCardWithoutMarkingItCancelled() {
    var state = ChatState()
    let request = ServerRequest.prompt(kind: "clarify", sessionID: "s", payload: ["prompt_id": "p1", "question": "Pick"])!
    state.attach(clarify: request)
    let effects = state.apply(event: "prompt.settled", payload: ["id": .string(request.id)], now: 2)
    #expect(effects == [.requestCancelled(request.id)])
    #expect(state.items[0].tool?.pendingRequest == nil)
    #expect(state.items[0].tool?.isCancelled == false)
  }

  @Test func aSnapshotCarriesItsOpenQuestions() {
    let live = LiveSession(json: [
      "session_id": "local-9", "stored_session_id": "local-9", "running": true, "messages": [],
      "prompts": [["kind": "clarify", "prompt_id": "q", "execution_generation": 2, "question": "Go?", "choices": []]],
    ])
    #expect(live.isRunning)
    #expect(live.liveID == "local-9")
    #expect(live.openRequests.map(\.method) == ["clarify"])
    #expect(live.openRequests.first?.sessionID == "local-9")
  }

  @Test func aRunningTurnsTextIsRebuiltFromItsReplay() throws {
    let events: [JSONValue] = [
      ["type": "message.start", "execution_generation": 2, "payload": [:]],
      ["type": "message.delta", "execution_generation": 1, "payload": ["text": "old turn"]],
      ["type": "message.delta", "execution_generation": 2, "payload": ["text": "Looking"]],
      ["type": "message.delta", "execution_generation": 2, "payload": ["text": " first."]],
      ["type": "tool.start", "execution_generation": 2, "payload": ["tool_id": "t1"]],
      ["type": "message.delta", "execution_generation": 2, "payload": ["text": .null]],
      ["type": "message.interim", "execution_generation": 2, "payload": ["text": "Now the second."]],
      ["type": "message.delta", "execution_generation": 2, "payload": ["text": "Almost"]],
    ]
    let inflight = try #require(HermesClient.inflight(fromReplay: events, generation: 2))
    // As `hermes serve` kept it: the deltas as streamed, an interim-only note left out.
    #expect(inflight["assistant"] == "Looking first.Almost")
    #expect(inflight["streaming"] == true)
    #expect(HermesClient.inflight(fromReplay: [["type": "tool.start", "payload": [:]]], generation: nil) == nil)
  }

  @Test func reasonCodesReadAsWords() {
    #expect(HermesError.rpc(code: -32000, message: "session_busy", reason: "session_busy").errorDescription == "The chat is busy right now.")
    #expect(HermesError.rpc(code: -32000, message: "Already running", reason: "session_busy").errorDescription == "Already running")
    #expect(HermesError.rpc(code: -32000, message: "permission_denied", reason: "permission_denied").isSessionGone)
    #expect(HermesError.rpc(code: -32000, message: "x", reason: "stale_generation").isStaleFence)
  }
}

@Suite struct GatewayPictureTests {
  @Test func picturesSentWithAGatewayTurnShowAsPictures() {
    let stored = "What color is this?\n\n[Image attached at: /m/a b.png]\n[Image attached at: /m/c.png]\n[screenshot]\n[screenshot]"
    let content = UserContent(stored)
    #expect(content.text == "What color is this?")
    #expect(content.images == ["/m/a b.png", "/m/c.png"])
    #expect(UserContent.preview(stored) == "What color is this?")
  }

  @Test func wordsThatLookLikeTheMarkerStayWords() {
    let typed = "Why does it say [Image attached at: /x.png] in the log?"
    #expect(UserContent(typed).text == typed)
    #expect(UserContent(typed).images.isEmpty)
    // A count that does not match its placeholders is not the gateway's suffix.
    let odd = "hi\n\n[Image attached at: /x.png]\n[screenshot]\n[screenshot]"
    #expect(UserContent(odd).images.isEmpty)
  }
}
