import Foundation
import Testing

@testable import MusePocketCore

struct MuseVoiceTests {
  func event(
    _ event: String, id: String = "reply", parent: String? = nil, text: String? = nil, seq: Int = 1
  ) throws -> Data {
    var payload: [String: Any] = ["message_id": id]
    if let parent { payload["reply_to_message_id"] = parent }
    if let text { payload[event == "delta.text_append" ? "text" : "content"] = text }
    return try JSONSerialization.data(withJSONObject: [
      "type": "event", "event": event, "seq": seq, "payload": payload,
    ])
  }
  let ack = Data(#"{"result":{"message_id":"user"}}"#.utf8)
  @Test func discoversDefaultAndHonorsExplicitVM() throws {
    let list = Data(
      #"{"vm_list":[{"vm_id":"one","vm_auth_token":"a"},{"vm_id":"two","default":true,"vm_auth_token":"b"}]}"#
        .utf8)
    #expect(try MuseConnection(token: "account").selectedVM(list).id == "two")
    #expect(try MuseConnection(vm: "one", token: "account").selectedVM(list).token == "a")
    #expect(throws: (any Error).self) {
      try MuseConnection(vm: "missing", token: "account").selectedVM(list)
    }
  }
  @Test func invalidConfigurationCannotLeakCredentials() throws {
    for host in [
      "https://evil.example", "evil.example/path", "evil.example@host", "localhost", "bad\r\nhost",
    ] {
      #expect(throws: (any Error).self) { try MuseConnection(host: host, token: "token") }
    }
    #expect(throws: (any Error).self) { try MuseConnection(token: "bad\r\ntoken") }
    #expect(throws: (any Error).self) { try MuseConnection(token: "vm-token", directVMToken: true) }
    let request = try MuseConnection(token: "account").websocketRequest(
      vm: "a&b", token: "vm-token")
    #expect(request.url?.scheme == "wss")
    #expect(request.url?.path == "/v1/noise")
    #expect(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        == "a&b")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer vm-token")
    #expect(!(request.url?.absoluteString.contains("vm-token") ?? true))
  }
  @Test func voiceAttachmentUsesSDKContractAndLimits() throws {
    let samples = [Int16](repeating: 120, count: 4800)
    let wav = IMAAudio.wav(samples)
    let body = try MuseVoiceClient.voiceBody(wav)
    let value = try JSONDecoder().decode(JSONValue.self, from: body)
    #expect(value["message"].string == "")
    #expect(value["output_modality"].string == "text")
    let item = value["items"].array!.first!
    #expect(item["type"].string == "file")
    #expect(Data(base64Encoded: item["data_base64"].string!) == wav)
    #expect(throws: (any Error).self) {
      try MuseVoiceClient.voiceBody(IMAAudio.wav([Int16](repeating: 0, count: 4799)))
    }
    #expect(throws: (any Error).self) {
      try MuseVoiceClient.voiceBody(IMAAudio.wav([Int16](repeating: 0, count: 240001)))
    }
    var broken = wav
    broken[40] = 0
    #expect(throws: (any Error).self) { try MuseVoiceClient.voiceBody(broken) }
  }
  @Test func earlyEventsAreBoundToAcknowledgedTurn() throws {
    var collector = MuseReplyCollector()
    try collector.event(event("message.assistant", parent: "user", text: "Correct"))
    #expect(!collector.finished)
    try collector.acknowledge(ack)
    #expect(collector.finished)
    #expect(collector.reply == "Correct")
  }
  @Test func unrelatedAndReplayedRepliesAreIgnored() throws {
    var collector = MuseReplyCollector()
    try collector.acknowledge(ack)
    try collector.event(
      event("message.assistant", id: "other", parent: "someone-else", text: "Wrong", seq: 1))
    try collector.event(event("message.assistant", id: "orphan", text: "Wrong", seq: 2))
    try collector.event(event("delta.message_start", parent: "user", seq: 3))
    try collector.event(event("delta.text_append", text: "Hello", seq: 4))
    try collector.event(event("delta.text_append", text: "Hello", seq: 4))
    try collector.event(event("delta.message_done", seq: 5))
    #expect(collector.finished)
    #expect(collector.reply == "Hello")
  }
  @Test func incompleteOrEmptyRepliesCannotFinish() throws {
    var collector = MuseReplyCollector()
    try collector.acknowledge(ack)
    try collector.event(event("delta.message_start", parent: "user"))
    #expect(!collector.finished)
    try collector.event(event("delta.message_done", seq: 2))
    #expect(!collector.finished)
    #expect(throws: (any Error).self) { try collector.acknowledge(Data("{}".utf8)) }
  }
  @Test func parserAndReplyBounds() throws {
    var lines = MuseLines()
    #expect(try lines.add(Data("{\"type\":".utf8), end: false).isEmpty)
    #expect(try lines.add(Data("1}\n{}".utf8), end: true).count == 2)
    #expect(throws: PocketError.tooLarge) {
      try lines.add(Data(repeating: 65, count: 262145), end: false)
    }
    var collector = MuseReplyCollector()
    try collector.acknowledge(ack)
    #expect(throws: PocketError.tooLarge) {
      try collector.event(
        event("message.assistant", parent: "user", text: String(repeating: "a", count: 32769)))
    }
  }
  @Test func noiseRejectsWrongStateAndTruncatedHandshake() throws {
    let session = try MuseNoiseSession()
    #expect(throws: (any Error).self) { try session.request(stream: 1, path: "/chat/subscribe") }
    let fresh = try MuseNoiseSession()
    #expect(try fresh.handshake(1).count == 32)
    #expect(throws: (any Error).self) {
      try fresh.handshake(2, input: Data(repeating: 0, count: 95))
    }
    #expect(throws: (any Error).self) { try fresh.handshake(3) }
  }
  // These run only in the explicit integration runner / CI with a loopback
  // independent Python responder; plain swift test still runs all unit checks.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["MUSE_TEST_PORT"] != nil),
    arguments: [
      "voice", "text", "early", "maxvoice", "direct", "cancel", "auth", "redirect", "tamper",
      "reset",
      "disconnect", "timeout",
    ])
  func independentSDKWebSocket(scenario: String) async throws {
    let port = ProcessInfo.processInfo.environment["MUSE_TEST_PORT"]!
    let client = MuseVoiceClient(
      fetch: { _ in
        if scenario == "direct" { throw PocketError.malformed }
        return Data(
          #"{"vm_list":[{"vm_id":"fixture","vm_auth_token":"fixture-vm-token","default":true}]}"#
            .utf8)
      },
      socketFactory: { request in
        var request = request
        request.url = URL(string: "ws://127.0.0.1:\(port)/\(scenario)")!
        return MuseWebSocket(request: request)
      }, deadline: scenario == "timeout" ? .milliseconds(300) : .seconds(15),
      settle: .milliseconds(80))
    let connection = try MuseConnection(
      vm: scenario == "direct" ? "fixture" : "",
      token: scenario == "direct" ? "fixture-vm-token" : "fixture-account-token",
      directVMToken: scenario == "direct")
    if scenario == "cancel" {
      let task = Task { try await client.reply(connection: connection, text: "Hello Muse") }
      task.cancel()
      await #expect(throws: (any Error).self) { try await task.value }
      return
    }
    if ["auth", "redirect", "tamper", "reset", "disconnect", "timeout"].contains(scenario) {
      await #expect(throws: (any Error).self) {
        try await client.reply(connection: connection, text: "Hello Muse")
      }
    } else {
      let wav = IMAAudio.wav([Int16](repeating: 120, count: scenario == "maxvoice" ? 240000 : 4800))
      let reply = try await client.reply(
        connection: connection,
        text: scenario == "text" ? "Hello Muse" : nil, wav: scenario == "text" ? nil : wav)
      #expect(
        reply
          == (scenario == "text"
            ? "Muse fixture received the text." : "Muse fixture received the voice note."))
    }
  }
}
