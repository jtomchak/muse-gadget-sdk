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
    var reportedFailure: String?
    assistant.onFailure = { reportedFailure = $0 }
    assistant.deliver = { _, _ in XCTFail("No credentials must mean no reply delivery") }
    await assistant.receive([Int16](repeating: 120, count: 4800))
    if let note = assistant.inbox.first { await assistant.process(note) }
    XCTAssertEqual(assistant.inbox.count, 1)
    XCTAssertTrue(assistant.lastReply.isEmpty)
    XCTAssertTrue(assistant.status.contains("credentials"))
    XCTAssertEqual(reportedFailure, assistant.status)
    XCTAssertTrue(reportedFailure?.contains("note remains") == true)
  }
  func testMoeAuthorizationUsesExactVMAndRejectsInvalidHandoff() throws {
    let suite = "MusePocket.authorization-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let host = UUID().uuidString.lowercased() + ".fixture.invalid"
    let assistant = AssistantService(preferences: preferences)
    defer {
      preferences.removePersistentDomain(forName: suite)
      PocketKeychain.delete(PocketKeychain.museAccount(host))
    }
    XCTAssertThrowsError(try assistant.useMoeAuthorization(.object([
      "host": .string(host), "vm": .string(""), "token": .string("fixture-token"),
    ])))
    XCTAssertNil(PocketKeychain.read(PocketKeychain.museAccount(host)))
    try assistant.useMoeAuthorization(.object([
      "host": .string(host), "vm": .string("paired-vm"), "token": .string("fixture-token"),
    ]))
    XCTAssertEqual(assistant.museHost, host)
    XCTAssertEqual(assistant.museVM, "paired-vm")
    XCTAssertTrue(assistant.museDirectVMToken)
    XCTAssertEqual(assistant.engine, "muse")
    XCTAssertEqual(PocketKeychain.read(PocketKeychain.museAccount(host)), "fixture-token")
    let restored = AssistantService(preferences: preferences)
    XCTAssertEqual(restored.museVM, "paired-vm")
    XCTAssertTrue(restored.museDirectVMToken)
    XCTAssertThrowsError(try assistant.useMoeAuthorization(.object([
      "host": .string("https://invalid/path"), "vm": .string("other"),
      "token": .string("different-token"),
    ])))
    XCTAssertEqual(assistant.museHost, host)
    XCTAssertEqual(assistant.museVM, "paired-vm")
    XCTAssertEqual(PocketKeychain.read(PocketKeychain.museAccount(host)), "fixture-token")
  }
  func testEmptyTranscriptionKeepsRecordingAndDoesNotRequestMuse() async throws {
    let suite = "MusePocket.empty-transcript-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let client = MuseVoiceClient(fetch: { _ in
      XCTFail("An empty transcript must not reach Muse")
      throw PocketError.malformed
    })
    let assistant = AssistantService(
      preferences: preferences, inboxDirectory: directory, museClient: client,
      museCredential: { _ in "fixture-account-token" }, speechTranscriber: { _ in "  \n " })
    assistant.deliver = { _, _ in XCTFail("Empty speech must not produce a reply") }
    await assistant.receive([Int16](repeating: 120, count: 4800))
    if let note = assistant.inbox.first { await assistant.process(note) }
    XCTAssertEqual(assistant.inbox.count, 1)
    XCTAssertTrue(assistant.status.contains("No speech was recognized"))
    XCTAssertFalse(assistant.busy)
    XCTAssertTrue(assistant.lastTranscript.isEmpty)
    XCTAssertNil(assistant.inbox.first?.transcript)
    let note = try XCTUnwrap(assistant.inbox.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(note.filename).path))
  }
  func testNetworkRetryReusesSavedTranscript() async throws {
    guard let port = ProcessInfo.processInfo.environment["MUSE_TEST_PORT"] else {
      throw XCTSkip("Run through ios/tools/test-muse-relay.sh")
    }
    let suite = "MusePocket.transcript-retry-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let requests = MuseRequestCounter()
    var transcriptions = 0
    let client = MuseVoiceClient(fetch: { _ in
      await requests.increment()
      if await requests.count == 1 { throw PocketError.disconnected }
      return Data(#"{"vm_list":[{"vm_id":"fixture","vm_auth_token":"fixture-vm-token"}]}"#.utf8)
    }, socketFactory: { request in
      var request = request
      request.url = URL(string: "ws://127.0.0.1:\(port)/voice")!
      return MuseWebSocket(request: request)
    }, deadline: .seconds(15), settle: .milliseconds(80))
    let assistant = AssistantService(
      preferences: preferences, inboxDirectory: directory, museClient: client,
      museCredential: { _ in "fixture-account-token" }, speechTranscriber: { _ in
        transcriptions += 1
        return "Hello Muse"
      })
    var deliveries = 0
    assistant.deliver = { text, _ in
      deliveries += 1
      XCTAssertEqual(text, "Muse fixture received the text.")
    }
    await assistant.receive([Int16](repeating: 120, count: 4800))
    if await requests.count == 0, let note = assistant.inbox.first { await assistant.process(note) }
    XCTAssertEqual(assistant.inbox.first?.transcript, "Hello Muse")
    XCTAssertNil(assistant.inbox.first?.reply)
    XCTAssertEqual(transcriptions, 1)
    XCTAssertFalse(assistant.busy)
    let note = try XCTUnwrap(assistant.inbox.first)
    await assistant.process(note)
    XCTAssertEqual(transcriptions, 1, "Network retry should use the saved transcript")
    XCTAssertEqual(deliveries, 1)
    XCTAssertTrue(assistant.inbox.isEmpty)
    let count = await requests.count
    XCTAssertEqual(count, 2)
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
    var transcriptions = 0
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
      museCredential: { _ in "fixture-account-token" }, speechTranscriber: { url in
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        transcriptions += 1
        return "Hello Muse"
      })
    assistant.museHost = host
    assistant.savePreferences()
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    var deliveries = 0
    assistant.deliver = { reply, pcm in
      deliveries += 1
      XCTAssertEqual(reply, "Muse fixture received the text.")
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
    XCTAssertEqual(note.reply, "Muse fixture received the text.")
    XCTAssertEqual(note.transcript, "Hello Muse")
    XCTAssertEqual(assistant.lastTranscript, "Hello Muse")
    XCTAssertEqual(transcriptions, 1)
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
