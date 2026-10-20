import Foundation

/// Matches firmware muse_adpcm: low nibble first, zero predictor/index per turn.
public enum IMAAudio {
  private static let steps = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73,
    80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494,
    544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499,
    2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
    11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
  ]
  private static let indices = [-1, -1, -1, -1, 2, 4, 6, 8]
  public static func decode(_ bytes: Data) -> [Int16] {
    var predictor = 0
    var index = 0
    var out = [Int16]()
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      for code in [Int(byte & 15), Int(byte >> 4)] {
        let step = steps[index]
        var diff = step >> 3
        if code & 1 != 0 { diff += step >> 2 }
        if code & 2 != 0 { diff += step >> 1 }
        if code & 4 != 0 { diff += step }
        predictor = max(-32768, min(32767, predictor + (code & 8 != 0 ? -diff : diff)))
        index = max(0, min(88, index + indices[code & 7]))
        out.append(Int16(predictor))
      }
    }
    return out
  }
  public static func encode(_ samples: [Int16]) -> Data {
    var predictor = 0
    var index = 0
    var out = Data()
    var low: UInt8 = 0
    for (n, sample) in samples.enumerated() {
      var delta = Int(sample) - predictor
      var code = 0
      if delta < 0 {
        code = 8
        delta = -delta
      }
      let step = steps[index]
      var diff = step >> 3
      if delta >= step {
        code |= 4
        delta -= step
        diff += step
      }
      if delta >= step >> 1 {
        code |= 2
        delta -= step >> 1
        diff += step >> 1
      }
      if delta >= step >> 2 {
        code |= 1
        diff += step >> 2
      }
      predictor = max(-32768, min(32767, predictor + (code & 8 != 0 ? -diff : diff)))
      index = max(0, min(88, index + indices[code & 7]))
      if n % 2 == 0 { low = UInt8(code) } else { out.append(low | UInt8(code) << 4) }
    }
    if samples.count % 2 != 0 { out.append(low) }
    return out
  }
  public static func wav(_ samples: [Int16], rate: UInt32 = 16000) -> Data {
    var d = Data()
    func text(_ s: String) { d.append(contentsOf: s.utf8) }
    func u32(_ v: UInt32) {
      for n in stride(from: 0, through: 24, by: 8) { d.append(UInt8((v >> n) & 255)) }
    }
    func u16(_ v: UInt16) {
      d.append(UInt8(v & 255))
      d.append(UInt8(v >> 8))
    }
    text("RIFF")
    u32(UInt32(samples.count * 2 + 36))
    text("WAVEfmt ")
    u32(16)
    u16(1)
    u16(1)
    u32(rate)
    u32(rate * 2)
    u16(2)
    u16(16)
    text("data")
    u32(UInt32(samples.count * 2))
    for sample in samples { u16(UInt16(bitPattern: sample)) }
    return d
  }
}
public struct VoiceAssembler: Sendable {
  public private(set) var turn: Int?, bytes = Data()
  public init() {}
  public mutating func begin(turn: Int) {
    self.turn = turn
    bytes.removeAll()
  }
  public mutating func append(turn: Int, offset: Int, base64: String) throws {
    guard self.turn == turn, bytes.count == offset, let data = Data(base64Encoded: base64),
      !data.isEmpty,
      bytes.count + data.count <= 120000
    else { throw PocketError.outOfOrder }
    bytes.append(data)
  }
  public mutating func finish(turn: Int, frames: Int, checksum: UInt32) throws -> [Int16] {
    guard self.turn == turn, frames > 0, frames <= 240000, (frames + 1) / 2 == bytes.count,
      CRC32.checksum(bytes) == checksum
    else { throw PocketError.checksum }
    defer {
      self.turn = nil
      bytes.removeAll()
    }
    return Array(IMAAudio.decode(bytes).prefix(frames))
  }
}
