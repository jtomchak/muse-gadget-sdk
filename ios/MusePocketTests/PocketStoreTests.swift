import MusePocketCore
import UIKit
import XCTest

@testable import MusePocket

@MainActor final class PocketStoreTests: XCTestCase {
  func testPreviewRequiresExplicitModeAndPersistsAcknowledgedSettings() async {
    let store = PocketStore(preview: true)
    XCTAssertTrue(store.ready)
    store.settings.name = "Desk Moe"
    store.settings.night = true
    await store.applySettings()
    XCTAssertNil(store.error)
    XCTAssertEqual(store.snapshot?.settings.name, "Desk Moe")
    XCTAssertTrue(store.snapshot?.settings.night ?? false)
  }
  func testPresetCardAndTimerFlow() async {
    let store = PocketStore(preview: true)
    let preset = PocketPreset(id: "tea-test", title: "Tea", detail: "Steep", seconds: 180)
    await store.preset(preset)
    XCTAssertTrue(store.snapshot?.presets.contains(preset) ?? false)
    await store.timer("start", preset: preset)
    XCTAssertEqual(store.snapshot?.timer["running"].bool, true)
    await store.timer("pause")
    XCTAssertEqual(store.snapshot?.timer["running"].bool, false)
    await store.timer("reset")
    XCTAssertEqual(store.snapshot?.timer["remaining"].number, 0)
    let card = PocketCard(id: "test-card", title: "Pack", body: "Coffee, charger")
    await store.card(card, show: true)
    XCTAssertTrue(store.snapshot?.cards.contains(card) ?? false)
    await store.removeCard(card.id)
    XCTAssertFalse(store.snapshot?.cards.contains(card) ?? true)
  }
  func testInvalidSettingsKeepAcknowledgedSnapshot() async {
    let store = PocketStore(preview: true)
    store.settings.shortcut = 5
    await store.applySettings()
    XCTAssertNotNil(store.error)
    XCTAssertEqual(store.snapshot?.settings.shortcut, 0)
  }
  func testTokenAccountsAreBoundToExactEndpoint() {
    XCTAssertNotEqual(
      PocketKeychain.relayAccount(URL(string: "https://one.example/relay")!),
      PocketKeychain.relayAccount(URL(string: "https://two.example/relay")!))
  }
  func testNativeHTTPStreamsAndEnforcesBothSizeLimits() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PocketTestURLProtocol.self]
    let (small, _) = try await PocketHTTP.data(
      for: URLRequest(url: URL(string: "https://pocket-test.invalid/small")!), limit: 16,
      configuration: configuration)
    XCTAssertEqual(small, Data("hello".utf8))
    for path in ["declared-large", "stream-large"] {
      do {
        _ = try await PocketHTTP.data(
          for: URLRequest(url: URL(string: "https://pocket-test.invalid/" + path)!), limit: 16,
          configuration: configuration)
        XCTFail("Oversize HTTPS responses must be rejected")
      } catch { XCTAssertEqual(error as? PocketError, .tooLarge) }
    }
  }
  func testAvatarHasExactRGB565Size() throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80)).image { ctx in
      UIColor.red.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    }
    let bytes = try AvatarPixels.encode(image)
    XCTAssertEqual(bytes.count, 8192)
  }
}

// URLProtocol's SDK callbacks own synchronization; this subclass adds no mutable state.
final class PocketTestURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "pocket-test.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let large = request.url!.path != "/small"
    let headers = request.url!.path == "/declared-large" ? ["Content-Length": "100"] : [:]
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: large ? Data(repeating: 65, count: 100) : Data("hello".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
