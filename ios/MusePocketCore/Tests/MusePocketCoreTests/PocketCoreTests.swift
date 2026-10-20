import Foundation
import Testing

@testable import MusePocketCore

struct PocketCoreTests {
  @Test func cxxWireAndCCodecFixtures() throws {
    let frame = try PocketFrame.encode(Data("hello".utf8), transfer: 0x1234, mtu: 20)[0]
    #expect(
      frame.map { String(format: "%02x", $0) }.joined() == "a10134120000010086a6103668656c6c6f")
    let pcm: [Int16] = [-32768, -12000, -1000, 0, 1000, 12000, 32767, 0]
    #expect(IMAAudio.encode(pcm).map { String(format: "%02x", $0) }.joined() == "ff5f77d7")
  }
  @Test func malformedNumbersCannotTrap() {
    #expect(JSONValue.number(1e100).integer(in: 0...Int(UInt32.max)) == nil)
    #expect(JSONValue.number(-1).integer(in: 0...100) == nil)
    #expect(JSONValue.number(1.5).integer(in: 0...100) == nil)
    #expect(JSONValue.number(.nan).integer(in: 0...100) == nil)
  }
  @Test(arguments: [20, 64, 185, 512]) func framedRoundTrip(mtu: Int) throws {
    let original = Data((0..<12000).map { UInt8($0 % 251) })
    let packets = try PocketFrame.encode(original, kind: .response, transfer: 42, mtu: mtu)
    var assembler = FrameAssembler()
    var result: (FrameKind, Data)?
    for packet in packets { result = try assembler.consume(packet, now: 1) }
    #expect(result?.0 == .response)
    #expect(result?.1 == original)
  }
  @Test func corruptionRejected() throws {
    var packets = try PocketFrame.encode(Data("test checksum".utf8), transfer: 1, mtu: 20)
    packets[0][12] ^= 1
    var rx = FrameAssembler()
    #expect(throws: PocketError.checksum) {
      for packet in packets { _ = try rx.consume(packet, now: 0) }
    }
  }
  @Test func missingAndExpiredPacketsRejected() throws {
    let packets = try PocketFrame.encode(Data(repeating: 8, count: 24), transfer: 1, mtu: 20)
    var rx = FrameAssembler()
    _ = try rx.consume(packets[0], now: 0)
    #expect(throws: PocketError.outOfOrder) { _ = try rx.consume(packets[2], now: 1) }
    _ = try rx.consume(packets[0], now: 0)
    #expect(throws: PocketError.outOfOrder) { _ = try rx.consume(packets[1], now: 31) }
  }
  @Test func boundaryAndInvalidHeader() throws {
    #expect(throws: PocketError.tooLarge) {
      _ = try PocketFrame.encode(Data(repeating: 1, count: 24577), transfer: 1, mtu: 512)
    }
    #expect(throws: PocketError.malformed) {
      _ = try PocketFrame(data: Data(repeating: 0, count: 12))
    }
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xcbf4_3926)
  }
  @Test func crossMidnightNightSchedule() {
    var settings = PocketSettings()
    settings.night = true
    #expect(settings.nightContains(minute: 1320))
    #expect(settings.nightContains(minute: 0))
    #expect(!settings.nightContains(minute: 420))
    #expect(!settings.nightContains(minute: 720))
    settings.nightStart = 60
    settings.nightEnd = 120
    #expect(settings.nightContains(minute: 60))
    #expect(!settings.nightContains(minute: 120))
    settings.nightEnd = 60
    #expect(!settings.nightContains(minute: 60))
  }
  @Test func byteLimitsPreserveUnicode() throws {
    let text = "Moe ☕️ 日本語"
    let trimmed = text.pocketPrefix(maxBytes: 10)
    #expect(trimmed.utf8.count <= 10)
    #expect(text.hasPrefix(trimmed))
    #expect(throws: (any Error).self) {
      _ = try PocketPreset(title: String(repeating: "☕", count: 20), detail: "", seconds: 1)
        .validated()
    }
    #expect(throws: (any Error).self) {
      _ = try PocketCard(title: "Card", body: String(repeating: "x", count: 161)).validated()
    }
    var settings = PocketSettings()
    settings.shortcut = 3
    #expect(throws: (any Error).self) { _ = try settings.validated() }
  }
  @Test(arguments: [0, 1, 2, 320, 16001]) func audioFraming(frames: Int) throws {
    let samples = (0..<frames).map { Int16(sin(Double($0) * 0.13) * 10000) }
    let bytes = IMAAudio.encode(samples)
    #expect(bytes.count == (frames + 1) / 2)
    #expect(IMAAudio.decode(bytes).count == bytes.count * 2)
    if frames > 0 {
      var voice = VoiceAssembler()
      voice.begin(turn: 7)
      try voice.append(turn: 7, offset: 0, base64: bytes.base64EncodedString())
      let decoded = try voice.finish(turn: 7, frames: frames, checksum: CRC32.checksum(bytes))
      #expect(decoded.count == frames)
      #expect(voice.turn == nil)
    }
    let wav = IMAAudio.wav(samples)
    #expect(wav.count == 44 + frames * 2)
    #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
  }
  @Test func audioMissingChunkIsRejected() throws {
    var voice = VoiceAssembler()
    voice.begin(turn: 1)
    #expect(throws: PocketError.outOfOrder) {
      try voice.append(turn: 1, offset: 10, base64: "AA==")
    }
    try voice.append(turn: 1, offset: 0, base64: "AA==")
    #expect(throws: PocketError.checksum) {
      _ = try voice.finish(turn: 1, frames: 2, checksum: 123)
    }
  }
  @Test(arguments: [
    "http://example.org", "https://user:password@example.org", "file:///tmp/firmware.bin",
  ]) func unsafeEndpointsRejected(value: String) {
    #expect(throws: (any Error).self) { try EndpointPolicy.validate(URL(string: value)!) }
  }
  @Test func manifestBoardAndChecksum() throws {
    let url = URL(string: "https://example.org/firmware.bin")!
    _ = try UpdateManifest(
      board: "waveshare_s3_175c", version: "0.1.0", url: url,
      sha256: String(repeating: "a", count: 64)
    ).validated()
    #expect(throws: (any Error).self) {
      _ = try UpdateManifest(
        board: "wrong", version: "1", url: url, sha256: String(repeating: "a", count: 64)
      ).validated()
    }
    #expect(throws: (any Error).self) {
      _ = try UpdateManifest(
        board: "waveshare_s3_175c", version: "1", url: url,
        sha256: String(repeating: "x", count: 64)
      ).validated()
    }
  }
  @Test func settingsSnapshotRoundTrip() throws {
    var settings = PocketSettings()
    settings.name = "Pocket Moe"
    settings.tilt = true
    settings.relay = true
    settings.clock24 = false
    let snapshot = PocketSnapshot(
      settings: settings, presets: [.init(title: "Tea", detail: "Steep", seconds: 180)],
      cards: [.init(title: "List", body: "Bring coffee")])
    let decoded = try JSONValue.from(snapshot).decode(PocketSnapshot.self)
    #expect(decoded.settings == settings)
    #expect(decoded.presets == snapshot.presets)
    #expect(decoded.cards == snapshot.cards)
  }
}
