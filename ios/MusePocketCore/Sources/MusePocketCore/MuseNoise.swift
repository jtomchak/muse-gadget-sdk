import CryptoKit
import Foundation
import MuseNoiseNative
import Security

// Apple supplies crypto; handshake, nonce accounting, protobuf and framing stay
// in the upstream C++ ClientSession shared with the ESP32.
private let appleMuseCrypto: MuseCrypto = { op, a, an, b, bn, c, cn, d, dn, out, count in
  func data(_ pointer: UnsafePointer<UInt8>?, _ size: Int) -> Data {
    size == 0 ? Data() : Data(bytes: pointer!, count: size)
  }
  do {
    let x = data(a, an)
    let y = data(b, bn)
    let z = data(c, cn)
    let w = data(d, dn)
    let result: Data
    switch op {
    case 0: return SecRandomCopyBytes(kSecRandomDefault, count, out!) == errSecSuccess ? 1 : 0
    case 1:
      let key = Curve25519.KeyAgreement.PrivateKey()
      result = key.rawRepresentation + key.publicKey.rawRepresentation
    case 2:
      result = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x).publicKey
        .rawRepresentation
    case 3:
      let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x)
        .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: y))
      result = secret.withUnsafeBytes { Data($0) }
      guard result.contains(where: { $0 != 0 }) else { return 0 }
    case 4: result = Data(SHA256.hash(data: x))
    case 5: result = Data(SHA256.hash(data: x + y))
    case 6:
      let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: y), salt: x, info: z, outputByteCount: count)
      result = key.withUnsafeBytes { Data($0) }
    case 7:
      let sealed = try AES.GCM.seal(
        w, using: SymmetricKey(data: x), nonce: AES.GCM.Nonce(data: y), authenticating: z)
      result = sealed.ciphertext + sealed.tag
    case 8:
      guard w.count >= 16 else { return 0 }
      let sealed = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: y), ciphertext: w.dropLast(16), tag: w.suffix(16))
      result = try AES.GCM.open(sealed, using: SymmetricKey(data: x), authenticating: z)
    default: return 0
    }
    guard result.count == count else { return 0 }
    if count > 0 { result.copyBytes(to: out!, count: count) }
    return 1
  } catch { return 0 }
}

public struct MuseFrame: Sendable {
  public let kind: Int, stream: Int64, status: Int, end: Bool, body: Data
}

/// Serialized by MuseVoiceClient. All buffers are bounded; no socket or token logging.
public final class MuseNoiseSession {
  private let handle: UnsafeMutableRawPointer
  public init() throws {
    guard let handle = muse_noise_create(appleMuseCrypto) else { throw PocketError.tooLarge }
    self.handle = handle
  }
  deinit { muse_noise_destroy(handle) }
  private func check(_ code: Int32) throws {
    guard code == 0 else {
      throw PocketError.rejected(
        "Muse encrypted transport failed (\(code)). Reconnect before retrying.")
    }
  }
  public func handshake(_ step: Int, input: Data = Data()) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65536)
    var count = 0
    let code = input.withUnsafeBytes { raw in
      muse_noise_handshake(
        handle, Int32(step), raw.bindMemory(to: UInt8.self).baseAddress, input.count, &bytes,
        bytes.count, &count)
    }
    try check(code)
    return Data(bytes.prefix(count))
  }
  public func request(stream: Int64, path: String, body: Data = Data(), end: Bool = true) throws
    -> [Data]
  {
    let code = body.withUnsafeBytes { raw in
      path.withCString { path in
        muse_noise_request(
          handle, stream, path, raw.bindMemory(to: UInt8.self).baseAddress, body.count, end ? 1 : 0)
      }
    }
    try check(code)
    return try drain()
  }
  public func chunk(stream: Int64, body: Data, end: Bool) throws -> [Data] {
    let code = body.withUnsafeBytes { raw in
      muse_noise_body(
        handle, stream, raw.bindMemory(to: UInt8.self).baseAddress, body.count, end ? 1 : 0)
    }
    try check(code)
    return try drain()
  }
  private func drain() throws -> [Data] {
    var result: [Data] = []
    while true {
      var bytes = [UInt8](repeating: 0, count: 65536)
      var count = 0
      try check(muse_noise_next(handle, &bytes, bytes.count, &count))
      if count == 0 { return result }
      result.append(Data(bytes.prefix(count)))
    }
  }
  public func receive(_ data: Data) throws -> MuseFrame? {
    var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
    var count = 0
    var kind: Int32 = 0
    var status: Int32 = 0
    var end: Int32 = 0
    var stream: Int64 = 0
    let code = data.withUnsafeBytes { raw in
      muse_noise_receive(
        handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count,
        &kind, &stream, &status, &end, &bytes, bytes.count, &count)
    }
    try check(code)
    guard kind != 0 else { return nil }
    return MuseFrame(
      kind: Int(kind), stream: stream, status: Int(status), end: end != 0,
      body: Data(bytes.prefix(count)))
  }
}
