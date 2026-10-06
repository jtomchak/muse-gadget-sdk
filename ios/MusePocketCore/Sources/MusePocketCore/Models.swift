import Foundation

public struct PocketSettings: Codable, Equatable, Sendable {
  public var clock = true, tap = false, tilt = false, night = false, clock24 = true,
    notifications = false, relay = false
  public var shortcut = 0, tapThreshold = 800, nightStart = 22 * 60, nightEnd = 7 * 60
  public var accent = 0xB8A3FF, avatar = 0
  public var name = "Moe", timezone = "MST7"
  public init() {}
  public func validated() throws -> Self {
    guard (0...2).contains(shortcut), (400...2000).contains(tapThreshold),
      (0...1439).contains(nightStart),
      (0...1439).contains(nightEnd), (0...0xffffff).contains(accent), (0...3).contains(avatar),
      !name.isEmpty, name.utf8.count <= 24, !timezone.isEmpty, timezone.utf8.count <= 63
    else { throw PocketError.rejected("Some settings exceed Moe’s supported range.") }
    return self
  }
  public func nightContains(minute: Int) -> Bool {
    guard night, nightStart != nightEnd else { return false }
    return nightStart < nightEnd
      ? (minute >= nightStart && minute < nightEnd) : (minute >= nightStart || minute < nightEnd)
  }
}
public struct PocketPreset: Codable, Identifiable, Equatable, Sendable {
  public var id: String, title: String, detail: String
  public var seconds: Int
  public init(id: String = UUID().uuidString, title: String, detail: String, seconds: Int) {
    self.id = id
    self.title = title
    self.detail = detail
    self.seconds = seconds
  }
  public func validated() throws -> Self {
    guard !id.isEmpty, id.utf8.count <= 36, !title.isEmpty, title.utf8.count <= 32,
      detail.utf8.count <= 160, (1...86400).contains(seconds)
    else {
      throw PocketError.rejected(
        "Use a title up to 32 bytes, details up to 160 bytes, and a duration between 1 second and 24 hours."
      )
    }
    return self
  }
}
public struct PocketCard: Codable, Identifiable, Equatable, Sendable {
  public var id: String, title: String, body: String, source: String
  public var expires: Int64
  public init(
    id: String = UUID().uuidString, title: String, body: String, source: String = "MusePocket",
    expires: Int64 = 0
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.source = source
    self.expires = expires
  }
  public func validated() throws -> Self {
    guard !id.isEmpty, id.utf8.count <= 36, !title.isEmpty, title.utf8.count <= 32,
      body.utf8.count <= 160, source.utf8.count <= 32, expires >= 0, expires <= 253_402_300_799
    else { throw PocketError.tooLarge }
    return self
  }
}
public struct PocketSnapshot: Codable, Sendable {
  public var settings: PocketSettings
  public var presets: [PocketPreset], cards: [PocketCard], capabilities: [String]
  public var device: JSONValue
  public var timer: JSONValue
  public var diagnostics: JSONValue
  public init(
    settings: PocketSettings = .init(), presets: [PocketPreset] = [], cards: [PocketCard] = [],
    capabilities: [String] = [], device: JSONValue = .object([:]), timer: JSONValue = .object([:]),
    diagnostics: JSONValue = .object([:])
  ) {
    self.settings = settings
    self.presets = presets
    self.cards = cards
    self.capabilities = capabilities
    self.device = device
    self.timer = timer
    self.diagnostics = diagnostics
  }
}
public struct UpdateManifest: Codable, Sendable {
  public let board: String, version: String, url: URL, sha256: String
  public init(board: String, version: String, url: URL, sha256: String) {
    self.board = board
    self.version = version
    self.url = url
    self.sha256 = sha256
  }
  public func validated() throws -> Self {
    guard board == "waveshare_s3_175c", !version.isEmpty, url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit })
    else {
      throw PocketError.rejected(
        "Choose a Waveshare 1.75C update manifest with an HTTPS image URL and SHA-256 digest.")
    }
    return self
  }
}
public enum EndpointPolicy {
  public static func validate(_ url: URL) throws {
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
      throw PocketError.rejected("Use an HTTPS URL without embedded credentials.")
    }
  }
}
extension String {
  public func pocketPrefix(maxBytes: Int) -> String {
    var result = ""
    var count = 0
    for character in self {
      let size = String(character).utf8.count
      if count + size > maxBytes { break }
      result.append(character)
      count += size
    }
    return result
  }
}
