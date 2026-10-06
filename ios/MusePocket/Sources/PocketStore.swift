import CryptoKit
import Foundation
import MusePocketCore
import Observation

@MainActor @Observable final class PocketStore {
  let bluetooth = BluetoothTransport(), assistant = AssistantService()
  let phoneCards = PhoneCards(), alerts = PocketAlerts()
  private(set) var snapshot: PocketSnapshot?
  private(set) var error: String?
  private(set) var notice: String?
  private(set) var busy = false
  private(set) var log: [String] = []
  private(set) var importedCards: [PocketCard] = []
  var preview = false
  var settings = PocketSettings()
  @ObservationIgnored private var voice = VoiceAssembler()
  @ObservationIgnored private var exportURL: URL?
  init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview")) {
    self.preview = preview
    bluetooth.onReady = { [weak self] in Task { await self?.refresh() } }
    bluetooth.onEvent = { [weak self] event in self?.event(event) }
    bluetooth.onDisconnect = { [weak self] in self?.record("Bluetooth disconnected") }
    assistant.deliver = { [weak self] text, pcm in
      guard let self else { throw PocketError.disconnected }
      try await self.deliverReply(text, pcm: pcm)
    }
    if preview {
      snapshot = PocketSnapshot(
        presets: [
          .init(id: "focus", title: "Focus", detail: "One task, 25 minutes", seconds: 1500),
          .init(id: "brew", title: "V60", detail: "15 g coffee · 250 g water", seconds: 180),
        ],
        cards: [
          .init(
            id: "demo", title: "Your pocket, organized",
            body: "Choose a timer, send a card, or customize Moe.")
        ],
        capabilities: [
          "settings", "clock", "gestures", "timers", "cards", "avatar", "find", "ota", "ancs",
          "relay",
        ],
        device: .object([
          "battery": .number(82), "fw": .string("MusePocket preview"),
          "wifi": .object(["state": .string("connected")]),
        ]), timer: .object(["running": .bool(false), "remaining": .number(0)]))
      settings = snapshot!.settings
    }
  }
  var ready: Bool { preview || bluetooth.protocolReady }
  var battery: String {
    guard let pct = snapshot?.device["battery"].integer(in: 0...100) else { return "—" }
    return "\(pct)%"
  }
  func report(_ error: Error) { self.error = error.localizedDescription }
  func dismissError() { error = nil }
  func record(_ message: String) {
    log.append(Date().formatted(date: .omitted, time: .standard) + " · " + message)
    if log.count > 100 { log.removeFirst(log.count - 100) }
  }
  func run(_ label: String, _ operation: () async throws -> Void) async {
    guard !busy else {
      error = "Wait for the current operation."
      return
    }
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      try await operation()
      record(label)
      notice = preview ? "Preview: " + label : label
    } catch {
      self.error = error.localizedDescription
      record(label + " failed")
    }
  }
  func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
    if preview { return try simulate(method, params) }
    return try await bluetooth.request(method, params: params)
  }
  private func simulate(_ method: String, _ params: JSONValue) throws -> JSONValue {
    guard var snap = snapshot else { throw PocketError.disconnected }
    switch method {
    case "settings.set":
      snap.settings = try params.decode(PocketSettings.self).validated()
      settings = snap.settings
    case "preset.put":
      let p = try params.decode(PocketPreset.self).validated()
      snap.presets.removeAll { $0.id == p.id }
      guard snap.presets.count < 8 else { throw PocketError.tooLarge }
      snap.presets.append(p)
    case "preset.delete": snap.presets.removeAll { $0.id == params["id"].string }
    case "card.put":
      let card = try params.decode(PocketCard.self).validated()
      snap.cards.removeAll { $0.id == card.id }
      guard snap.cards.count < 8 else { throw PocketError.tooLarge }
      snap.cards.append(card)
    case "card.delete": snap.cards.removeAll { $0.id == params["id"].string }
    case "timer.start":
      guard let preset = snap.presets.first(where: { $0.id == params["id"].string }) else {
        throw PocketError.rejected("Choose a preset.")
      }
      snap.timer = .object([
        "running": .bool(true), "remaining": .number(Double(preset.seconds)),
        "title": .string(preset.title),
      ])
    case "timer.pause":
      snap.timer = .object(["running": .bool(false), "remaining": snap.timer["remaining"]])
    case "timer.resume":
      snap.timer = .object(["running": .bool(true), "remaining": snap.timer["remaining"]])
    case "timer.reset": snap.timer = .object(["running": .bool(false), "remaining": .number(0)])
    default: break
    }
    snapshot = snap
    return try .from(snap)
  }
  func refresh() async { await run("Device refreshed") { try await self.loadSnapshot() } }
  private func loadSnapshot() async throws {
    let result = try await request("hello")
    snapshot = try result.decode(PocketSnapshot.self)
    if let snapshot { settings = snapshot.settings }
  }
  func applySettings() async {
    await run("Settings acknowledged by Moe") {
      _ = try settings.validated()
      _ = try await request("settings.set", .from(settings))
      try await loadSnapshot()
    }
  }
  func legacy(_ key: String, value: String) async {
    await run("\(key) applied") {
      if preview {
        if key == "brightness" {
          snapshot?.device = .object([
            "battery": .number(82), "brightness": .number(Double(value) ?? 80),
          ])
        }
        return
      }
      try await bluetooth.sendLegacy(key + "=" + value)
      try await loadSnapshot()
    }
  }
  func wifi(ssid: String, password: String) async {
    await run("Wi-Fi credentials sent; waiting for Moe to join") {
      guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 63 else {
        throw PocketError.rejected("Check the Wi-Fi name and password length.")
      }
      if preview { return }
      try await bluetooth.sendLegacy("wifi.ssid=" + ssid)
      try await bluetooth.sendLegacy("wifi.pass=" + password)
      try await bluetooth.sendLegacy("wifi.connect")
      if bluetooth.protocolReady { try await loadSnapshot() }
    }
  }
  func preset(_ preset: PocketPreset) async {
    await run("Preset saved on Moe") {
      _ = try preset.validated()
      _ = try await request("preset.put", .from(preset))
      try await loadSnapshot()
    }
  }
  func removePreset(_ id: String) async {
    await run("Preset removed") {
      _ = try await request("preset.delete", .object(["id": .string(id)]))
      try await loadSnapshot()
    }
  }
  func timer(_ action: String, preset: PocketPreset? = nil) async {
    await run("Timer \(action) acknowledged") {
      let params: JSONValue = preset.map { .object(["id": .string($0.id)]) } ?? .object([:])
      _ = try await request("timer." + action, params)
      try await loadSnapshot()
      if action == "start", let preset {
        alerts.schedule(seconds: preset.seconds, title: preset.title)
      } else if action == "pause" || action == "reset" {
        alerts.cancel()
      } else if action == "resume", let seconds = snapshot?.timer["remaining"].number {
        alerts.schedule(
          seconds: Int(seconds), title: snapshot?.timer["title"].string ?? "Timer complete")
      }
    }
  }
  func card(_ card: PocketCard, show: Bool = false) async {
    await run(show ? "Card sent to Moe’s screen" : "Card saved on Moe") {
      _ = try card.validated()
      _ = try await request("card.put", .from(card))
      if show { _ = try await request("card.show", .object(["id": .string(card.id)])) }
      try await loadSnapshot()
    }
  }
  func showCard(_ card: PocketCard) async {
    await run("Card selected on Moe") {
      _ = try await request("card.show", .object(["id": .string(card.id)]))
    }
  }
  func removeCard(_ id: String) async {
    await run("Card removed") {
      _ = try await request("card.delete", .object(["id": .string(id)]))
      try await loadSnapshot()
    }
  }
  func find() async {
    await run("Find signal requested; Moe plays it when idle") { _ = try await request("find") }
  }
  func sleep() async { await run("Standby requested") { _ = try await request("sleep") } }
  func syncTime() async {
    await run("Clock synchronized from iPhone") {
      _ = try await request(
        "time.set",
        .object([
          "epoch": .number(Date().timeIntervalSince1970.rounded()),
          "timezone": .string(settings.timezone),
        ]))
    }
  }
  func uploadAvatar(_ pixels: Data) async {
    await run("Avatar transferred to Moe") {
      guard pixels.count == 8192 else { throw PocketError.malformed }
      _ = try await request(
        "avatar.upload",
        .object([
          "data": .string(pixels.base64EncodedString()),
          "crc": .number(Double(CRC32.checksum(pixels))),
        ]))
      try await loadSnapshot()
    }
  }
  func importCalendar() async {
    await run("Calendar cards ready to choose") {
      importedCards =
        preview
        ? [
          .init(
            title: "Preview calendar", body: "A selected event appears here.", source: "Calendar")
        ] : try await phoneCards.calendar()
    }
  }
  func importReminders() async {
    await run("Reminder cards ready to choose") {
      importedCards =
        preview
        ? [
          .init(
            title: "Preview reminder", body: "A selected reminder appears here.",
            source: "Reminders")
        ] : try await phoneCards.reminders()
    }
  }
  func weather(latitude: Double, longitude: Double) async {
    await run("Weather card ready to choose") {
      importedCards =
        preview
        ? [
          .init(title: "Preview weather", body: "Weather loads when connected.", source: "Preview")
        ] : [try await phoneCards.weather(latitude: latitude, longitude: longitude)]
    }
  }
  func configureMuse(host: String, vm: String, token: String) async {
    await run("Muse connection settings sent") {
      guard !host.isEmpty, host.utf8.count <= 255, vm.utf8.count <= 128 else {
        throw PocketError.tooLarge
      }
      if preview { return }
      try await bluetooth.sendLegacy("hatch.host=" + host)
      try await bluetooth.sendLegacy("hatch.vm=" + vm)
      if !token.isEmpty {
        try PocketKeychain.save(token, name: "muse.token")
        let limit = min(400, 512)
        let bytes = [UInt8](token.utf8)
        for at in stride(from: 0, to: bytes.count, by: limit) {
          guard let piece = String(bytes: bytes[at..<min(at + limit, bytes.count)], encoding: .utf8)
          else { throw PocketError.malformed }
          try await bluetooth.sendLegacy((at == 0 ? "hatch.token=" : "hatch.token+=") + piece)
        }
      }
      try await bluetooth.sendLegacy("hatch.test")
      try await loadSnapshot()
    }
  }
  func audioTest() async {
    await run("Audio test requested") {
      if !preview { try await bluetooth.sendLegacy("test.loopback") }
    }
  }
  func install(_ manifest: UpdateManifest) async {
    await run("Firmware update requested; reconnect to confirm the installed version") {
      _ = try manifest.validated()
      if preview { return }
      var request = URLRequest(url: manifest.url)
      request.timeoutInterval = 60
      let (data, _) = try await PocketHTTP.data(for: request, limit: 4 * 1024 * 1024)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard digest == manifest.sha256.lowercased() else { throw PocketError.checksum }
      _ = try await self.request(
        "ota",
        .object([
          "board": .string(manifest.board), "url": .string(manifest.url.absoluteString),
          "version": .string(manifest.version), "sha256": .string(digest),
        ]))
    }
  }
  func exportDiagnostics() throws -> URL {
    let payload: JSONValue = .object([
      "app": .string("MusePocket 0.1"), "firmware": snapshot?.device["fw"] ?? .null,
      "diagnostics": snapshot?.diagnostics ?? .null, "events": .array(log.map { .string($0) }),
    ])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MusePocket-diagnostics.json")
    try JSONEncoder().encode(payload).write(to: url, options: .atomic)
    exportURL = url
    return url
  }
  private func event(_ envelope: JSONValue) {
    guard envelope["v"].number == 1, let name = envelope["event"].string else { return }
    let data = envelope["data"]
    handleEvent(name, data: data)
  }
  private func handleEvent(_ name: String, data: JSONValue) {
    do {
      switch name {
      case "voice.begin":
        guard let turn = data["turn"].integer(in: 0...Int(UInt32.max)) else {
          throw PocketError.malformed
        }
        voice.begin(turn: turn)
        assistant.status = "Receiving a voice note…"
      case "voice.chunk":
        try voice.append(
          turn: data["turn"].integer(in: 0...Int(UInt32.max)) ?? -1,
          offset: data["offset"].integer(in: 0...120000) ?? -1,
          base64: data["data"].string ?? "")
      case "voice.end":
        let pcm = try voice.finish(
          turn: data["turn"].integer(in: 0...Int(UInt32.max)) ?? -1,
          frames: data["frames"].integer(in: 1...240000) ?? 0,
          checksum: UInt32(data["crc"].integer(in: 0...Int(UInt32.max)) ?? 0))
        Task { await assistant.receive(pcm) }
      case "timer.done":
        alerts.cancel()
        notice = "Moe’s timer is complete."
        Task { await refresh() }
      default:
        notice = data["detail"].string
        record(name)
      }
    } catch {
      self.error = error.localizedDescription
      record("Voice transfer rejected")
    }
  }
  private func deliverReply(_ text: String, pcm: [Int16]?) async throws {
    guard !busy else {
      throw PocketError.rejected("Finish the current device operation, then retry this note.")
    }
    busy = true
    defer { busy = false }
    let turn = Int(UInt32.random(in: 0...UInt32.max))
    _ = try await request(
      "reply.text", .object(["text": .string(text.pocketPrefix(maxBytes: 360))]))
    guard let pcm, !pcm.isEmpty else { return }
    let encoded = IMAAudio.encode(pcm)
    _ = try await request(
      "reply.begin",
      .object([
        "turn": .number(Double(turn)), "frames": .number(Double(pcm.count)),
        "crc": .number(Double(CRC32.checksum(encoded))),
      ]))
    for offset in stride(from: 0, to: encoded.count, by: 2048) {
      let chunk = encoded[offset..<min(offset + 2048, encoded.count)]
      _ = try await request(
        "reply.part",
        .object([
          "turn": .number(Double(turn)), "offset": .number(Double(offset)),
          "data": .string(chunk.base64EncodedString()),
        ]))
    }
    _ = try await request("reply.end", .object(["turn": .number(Double(turn))]))
  }
}
