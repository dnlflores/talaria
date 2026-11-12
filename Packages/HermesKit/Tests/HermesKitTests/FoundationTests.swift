import Foundation
import Testing

@testable import HermesKit

@Suite struct JSONValueTests {
  @Test func parsesBooleansAndNumbersApart() throws {
    let json = try JSONValue.parse(#"{"flag":true,"zero":0,"one":1,"text":"hi","list":[1,"a",null],"nested":{"k":2.5}}"#)
    #expect(json["flag"] == .bool(true))
    #expect(json["zero"] == .number(0))
    #expect(json["one"].int == 1)
    #expect(json["text"].string == "hi")
    #expect(json["list"][1].string == "a")
    #expect(json["list"][2].isNull)
    #expect(json["nested"]["k"].double == 2.5)
    #expect(json["missing"]["deeper"].isNull)
  }

  @Test func wholeNumbersSerializeWithoutFraction() throws {
    let value: JSONValue = ["expected_revision": 2, "ratio": 0.5, "ok": true, "none": nil]
    let round = try JSONValue.parse(value.text())
    #expect(value.text().contains("\"expected_revision\":2"))
    #expect(!value.text().contains("2.0"))
    #expect(round == value)
  }

  @Test func truthinessCoversSQLiteIntegers() {
    #expect(JSONValue.number(1).truthy)
    #expect(!JSONValue.number(0).truthy)
    #expect(JSONValue.bool(true).truthy)
    #expect(!JSONValue.null.truthy)
    #expect(!JSONValue.string("").truthy)
  }

  @Test func scalarTextKeepsIntegerIDsClean() {
    #expect(JSONValue.number(42).scalarText == "42")
    #expect(JSONValue.string("call_1").scalarText == "call_1")
    #expect(JSONValue.array([]).scalarText == nil)
  }

  @Test func fieldsDropsNilValues() {
    let value = JSONValue.fields(["a": "x", "b": nil, "c": 1])
    #expect(value.object?.keys.sorted() == ["a", "c"])
  }

  @Test func parsesJSONCarriedAsAString() {
    let value = JSONValue.string(#"{"questions":["a"]}"#)
    #expect(value.parsedIfJSONString["questions"][0].string == "a")
    #expect(JSONValue.string("plain").parsedIfJSONString == .string("plain"))
  }
}

@Suite struct ServerEndpointTests {
  @Test func bareHostGetsHTTPS() throws {
    let endpoint = try #require(ServerEndpoint(userInput: "  my-mac.example.ts.net:8443/ "))
    #expect(endpoint.baseURL.absoluteString == "https://my-mac.example.ts.net:8443")
    #expect(endpoint.origin == "https://my-mac.example.ts.net:8443")
    #expect(endpoint.webSocketURL.absoluteString == "wss://my-mac.example.ts.net:8443/api/ws")
    #expect(endpoint.displayName == "my-mac.example.ts.net:8443")
  }

  @Test func loopbackGetsHTTP() throws {
    let endpoint = try #require(ServerEndpoint(userInput: "127.0.0.1:4300"))
    #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:4300")
    #expect(endpoint.webSocketURL.absoluteString == "ws://127.0.0.1:4300/api/ws")
    #expect(!endpoint.isSecure)
  }

  @Test func rejectsWhatIsNotAnAddress() {
    #expect(ServerEndpoint(userInput: "") == nil)
    #expect(ServerEndpoint(userInput: "ftp://host") == nil)
    #expect(ServerEndpoint(userInput: "https://user:secret@host") == nil)
  }

  @Test func encodesPathSegmentsAndQuery() throws {
    let endpoint = try #require(ServerEndpoint(userInput: "https://host/prefix"))
    let url = endpoint.url(path: "/api/sessions/agent:main:abc/messages", query: [("profile", "my bot&co")])
    #expect(url.absoluteString == "https://host/prefix/api/sessions/agent%3Amain%3Aabc/messages?profile=my%20bot%26co")
  }

  @Test func formEncodingProtectsReservedCharacters() {
    #expect(ServerEndpoint.formEncode("a+b&c=d e/é") == "a%2Bb%26c%3Dd%20e%2F%C3%A9")
  }
}

@Suite struct HermesErrorTests {
  @Test func recognizesSessionGone() {
    #expect(HermesError.rpc(code: 4007, message: "x", reason: nil).isSessionGone)
    #expect(HermesError.rpc(code: 0, message: "Session not found: abc", reason: nil).isSessionGone)
    #expect(!HermesError.rpc(code: -32601, message: "unknown method", reason: nil).isSessionGone)
  }

  @Test func recognizesChatsHeldElsewhere() {
    #expect(HermesError.rpc(code: 0, message: "This chat is open in another Hermes window", reason: nil).isOwnedElsewhere)
    #expect(HermesError.rpc(code: 0, message: "refused", reason: "SESSION_NOT_OWNED").isOwnedElsewhere)
    #expect(!HermesError.notConnected.isOwnedElsewhere)
  }

  @Test func readsErrorMessagesFromBodies() throws {
    #expect(HermesHTTP.message(from: try JSONValue.parse(#"{"detail":"session_busy"}"#), status: 409) == "session_busy")
    #expect(HermesHTTP.message(from: .string("<html>nope</html>"), status: 502) == "HTTP 502")
  }
}
