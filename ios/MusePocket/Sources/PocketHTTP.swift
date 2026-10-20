import Foundation
import MusePocketCore

/// Keeps credentials on the configured origin and bounds each streamed response.
final class PocketHTTPSDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Firmware uses the same no-redirect rule. Configure the final HTTPS endpoint.
    completionHandler(nil)
  }
}
enum PocketHTTP {
  static func data(
    for request: URLRequest, limit: Int, configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw PocketError.malformed }
    try EndpointPolicy.validate(url)
    let session = URLSession(
      configuration: configuration, delegate: PocketHTTPSDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode)
    else {
      throw PocketError.rejected(
        "The HTTPS endpoint did not return a successful response. Use its final URL without redirects."
      )
    }
    guard response.expectedContentLength <= Int64(limit) else { throw PocketError.tooLarge }
    var data = Data()
    data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
    for try await byte in stream {
      guard data.count < limit else { throw PocketError.tooLarge }
      data.append(byte)
    }
    return (data, response)
  }
}
