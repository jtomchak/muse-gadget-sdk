import Foundation
import MusePocketCore
import XCTest

@testable import MusePocket

@MainActor final class MuseAssistantTests: XCTestCase {
  func testMissingCredentialsRetainsNoteAndDoesNotInventReply() async throws {
    let suite = "MusePocket.voice-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let assistant = AssistantService(preferences: preferences, inboxDirectory: directory)
    assistant.museHost = UUID().uuidString.lowercased() + ".fixture.invalid"
    assistant.deliver = { _, _ in XCTFail("No credentials must mean no reply delivery") }
    await assistant.receive([Int16](repeating: 120, count: 4800))
    if let note = assistant.inbox.first { await assistant.process(note) }
    XCTAssertEqual(assistant.inbox.count, 1)
    XCTAssertTrue(assistant.lastReply.isEmpty)
    XCTAssertTrue(assistant.status.contains("credentials"))
  }
  func testMuseInboxNativeSpeechAndCachedDeliveryRetry() async throws {
    guard let port = ProcessInfo.processInfo.environment["MUSE_TEST_PORT"] else {
      throw XCTSkip("Run through ios/tools/test-muse-relay.sh for independent SDK integration")
    }
    let suite = "MusePocket.voice-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let host = UUID().uuidString.lowercased() + ".fixture.invalid"
    let requests = MuseRequestCounter()
    let client = MuseVoiceClient(
      fetch: { _ in
        await requests.increment()
        return Data(#"{"vm_list":[{"vm_id":"fixture","vm_auth_token":"fixture-vm-token"}]}"#.utf8)
      },
      socketFactory: { request in
        var request = request
        request.url = URL(string: "ws://127.0.0.1:\(port)/voice")!
        return MuseWebSocket(request: request)
      }, deadline: .seconds(15), settle: .milliseconds(80))
    let assistant = AssistantService(
      preferences: preferences, inboxDirectory: directory, museClient: client,
      museCredential: { _ in "fixture-account-token" })
    assistant.museHost = host
    assistant.savePreferences()
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    var deliveries = 0
    assistant.deliver = { reply, pcm in
      deliveries += 1
      XCTAssertEqual(reply, "Muse fixture received the voice note.")
      XCTAssertGreaterThan(pcm?.count ?? 0, 0)
      XCTAssertLessThanOrEqual(pcm?.count ?? Int.max, 240000)
      if deliveries == 1 { throw PocketError.disconnected }
    }
    // Simulate the exact decoded BLE recording delivered by PocketStore.
    var voice = VoiceAssembler()
    voice.begin(turn: 77)
    let input = IMAAudio.encode([Int16](repeating: 120, count: 4800))
    try voice.append(turn: 77, offset: 0, base64: input.base64EncodedString())
    let samples = try voice.finish(turn: 77, frames: 4800, checksum: CRC32.checksum(input))
    await assistant.receive(samples)
    if deliveries == 0, let note = assistant.inbox.first { await assistant.process(note) }
    XCTAssertEqual(deliveries, 1)
    XCTAssertEqual(assistant.inbox.count, 1)
    let note = try XCTUnwrap(assistant.inbox.first)
    XCTAssertEqual(note.reply, "Muse fixture received the voice note.")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(note.filename).path))
    let resumed = AssistantService(preferences: preferences, inboxDirectory: directory)
    resumed.deliver = assistant.deliver
    let restored = try XCTUnwrap(resumed.inbox.first)
    XCTAssertEqual(restored.reply, note.reply)
    await resumed.process(restored)
    XCTAssertEqual(deliveries, 2)
    XCTAssertTrue(resumed.inbox.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(note.filename).path))
    let count = await requests.count
    XCTAssertEqual(
      count, 1, "Retry must deliver cached reply instead of creating a second Muse request")
  }
}
private actor MuseRequestCounter {
  var count = 0
  func increment() { count += 1 }
}
