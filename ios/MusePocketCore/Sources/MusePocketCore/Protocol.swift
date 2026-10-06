import Foundation

public enum PocketUUID {
  public static let advertisedService = "7FDD3D1C-38EA-46CF-8B46-314ECF5F240C"
  public static let service = "4D757365-0001-4000-8000-6A6F6C6C7900"
  public static let legacyCommand = "4D757365-0002-4000-8000-6A6F6C6C7900"
  public static let legacyStatus = "4D757365-0003-4000-8000-6A6F6C6C7900"
  public static let command = "4D757365-0004-4000-8000-6A6F6C6C7900"
  public static let response = "4D757365-0005-4000-8000-6A6F6C6C7900"
}
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSONValue {
    if case .object(let o) = self { return o[key] ?? .null }
    return .null
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  public var number: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
  public func integer(in range: ClosedRange<Int>) -> Int? {
    guard let number, let value = Int(exactly: number), range.contains(value) else { return nil }
    return value
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var array: [JSONValue]? {
    if case .array(let v) = self { return v }
    return nil
  }
  public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}
public struct PocketRequest: Codable, Sendable {
  public let v: Int = 1
  private enum CodingKeys: String, CodingKey { case id, method, params, v }
  public let id: String
  public let method: String
  public let params: JSONValue
  public init(id: String = UUID().uuidString, method: String, params: JSONValue = .object([:])) {
    self.id = id
    self.method = method
    self.params = params
  }
}
public struct PocketResponse: Codable, Sendable {
  public let v: Int
  public let id: String
  public let ok: Bool
  public let result: JSONValue?
  public let error: String?
}
public enum PocketError: Error, LocalizedError, Equatable {
  case disconnected, timeout, malformed, tooLarge, checksum, outOfOrder
  case rejected(String)
  case incompatible
  public var errorDescription: String? {
    switch self {
    case .disconnected: "Connect to Moe first."
    case .timeout: "Moe did not acknowledge this request. Reconnect and refresh before retrying."
    case .malformed: "The device sent an invalid message."
    case .tooLarge: "This content exceeds Moe’s storage limit."
    case .checksum: "The transfer was incomplete or damaged."
    case .outOfOrder: "A Bluetooth packet was missing. Please retry."
    case .rejected(let m): m
    case .incompatible: "This firmware needs the MusePocket protocol v1 update."
    }
  }
}
public enum FrameKind: UInt8, Sendable {
  case request = 0xA1
  case response = 0xA2
  case event = 0xA3
}
public struct PocketFrame: Sendable {
  public static let header = 12, limit = 24576, maxParts = 4096
  public let kind: FrameKind, transfer: UInt16, index: UInt16, total: UInt16, checksum: UInt32,
    payload: Data
  public init(data: Data) throws {
    let b = [UInt8](data)
    guard b.count > Self.header, b[1] == 1, let kind = FrameKind(rawValue: b[0]) else {
      throw PocketError.malformed
    }
    func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    self.kind = kind
    transfer = u16(2)
    index = u16(4)
    total = u16(6)
    checksum = UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24
    payload = data.dropFirst(Self.header)
    guard total > 0, total <= Self.maxParts, index < total else { throw PocketError.malformed }
  }
  public static func encode(_ data: Data, kind: FrameKind = .request, transfer: UInt16, mtu: Int)
    throws -> [Data]
  {
    guard !data.isEmpty, data.count <= limit else { throw PocketError.tooLarge }
    guard mtu > header else { throw PocketError.malformed }
    let size = mtu - header
    let total = (data.count + size - 1) / size
    guard total <= maxParts else { throw PocketError.tooLarge }
    let crc = CRC32.checksum(data)
    return (0..<total).map { index in
      var packet = Data([kind.rawValue, 1])
      for value in [transfer, UInt16(index), UInt16(total)] {
        packet.append(UInt8(value & 255))
        packet.append(UInt8(value >> 8))
      }
      for shift in stride(from: 0, through: 24, by: 8) {
        packet.append(UInt8((crc >> shift) & 255))
      }
      packet.append(data[(index * size)..<min((index + 1) * size, data.count)])
      return packet
    }
  }
}
public struct FrameAssembler: Sendable {
  private var first: PocketFrame?, next: UInt16 = 0, bytes = Data(), began: TimeInterval = 0
  public init() {}
  public mutating func reset() {
    first = nil
    next = 0
    bytes.removeAll()
    began = 0
  }
  public mutating func consume(_ data: Data, now: TimeInterval) throws -> (FrameKind, Data)? {
    let f: PocketFrame
    do { f = try PocketFrame(data: data) } catch {
      reset()
      throw error
    }
    if f.index == 0 {
      reset()
      first = f
      began = now
    }
    guard let initial = first, now - began <= 30, f.kind == initial.kind,
      f.transfer == initial.transfer,
      f.total == initial.total, f.checksum == initial.checksum, f.index == next
    else {
      reset()
      throw PocketError.outOfOrder
    }
    guard bytes.count + f.payload.count <= PocketFrame.limit else {
      reset()
      throw PocketError.tooLarge
    }
    bytes.append(f.payload)
    next += 1
    if next == f.total {
      let result = bytes
      reset()
      guard CRC32.checksum(result) == f.checksum else { throw PocketError.checksum }
      return (f.kind, result)
    }
    return nil
  }
}
public enum CRC32 {
  public static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
    }
    return ~crc
  }
}
