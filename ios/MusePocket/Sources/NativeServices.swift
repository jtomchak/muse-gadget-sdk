import EventKit
import Foundation
import MusePocketCore
import SwiftUI
import UIKit
import UserNotifications

@MainActor final class PhoneCards {
  private let events = EKEventStore()
  func calendar() async throws -> [PocketCard] {
    guard try await events.requestFullAccessToEvents() else {
      throw PocketError.rejected("Calendar access was declined. You can still make cards manually.")
    }
    let now = Date()
    let end = now.addingTimeInterval(86400 * 2)
    return events.events(
      matching: events.predicateForEvents(withStart: now, end: end, calendars: nil)
    ).sorted { $0.startDate < $1.startDate }.prefix(8).map { event in
      let date = event.startDate.formatted(date: .abbreviated, time: .shortened)
      return PocketCard(
        id: event.eventIdentifier.pocketPrefix(maxBytes: 36),
        title: (event.title ?? "Event").pocketPrefix(maxBytes: 32),
        body: (date + (event.location.map { " · " + $0 } ?? "")).pocketPrefix(maxBytes: 160),
        source: "Calendar", expires: Int64(event.endDate.timeIntervalSince1970))
    }
  }
  func reminders() async throws -> [PocketCard] {
    guard try await events.requestFullAccessToReminders() else {
      throw PocketError.rejected("Reminders access was declined.")
    }
    let predicate = events.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    return await withCheckedContinuation { continuation in
      events.fetchReminders(matching: predicate) { reminders in
        let cards = (reminders ?? []).prefix(8).map {
          PocketCard(
            title: ($0.title ?? "Reminder").pocketPrefix(maxBytes: 32),
            body: ($0.notes ?? "No additional details").pocketPrefix(maxBytes: 160),
            source: "Reminders")
        }
        continuation.resume(returning: cards)
      }
    }
  }
  func weather(latitude: Double, longitude: Double) async throws -> PocketCard {
    guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
      throw PocketError.rejected("Enter a valid latitude and longitude.")
    }
    var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    url.queryItems = [
      URLQueryItem(name: "latitude", value: String(latitude)),
      URLQueryItem(name: "longitude", value: String(longitude)),
      URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
      URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
    ]
    var request = URLRequest(url: url.url!)
    request.timeoutInterval = 15
    let (data, response) = try await PocketHTTP.data(for: request, limit: 65_536)
    guard response.statusCode == 200 else {
      throw PocketError.rejected("Weather could not be loaded.")
    }
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let temperature = json["current"]["temperature_2m"].number,
      temperature.isFinite, (-150...160).contains(temperature)
    else {
      throw PocketError.malformed
    }
    let code = json["current"]["weather_code"].integer(in: 0...99) ?? -1
    let description =
      code == 0
      ? "Clear"
      : code <= 3
        ? "Cloudy"
        : code >= 95
          ? "Thunderstorms" : code >= 71 && code <= 86 ? "Snow" : code >= 51 ? "Rain" : "Fog"
    return PocketCard(
      id: "weather", title: "Weather", body: "\(Int(temperature.rounded()))°F · \(description)",
      source: "Open-Meteo", expires: Int64(Date().timeIntervalSince1970 + 3600))
  }
}
@MainActor final class PocketAlerts {
  func authorize() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }
  func schedule(seconds: Int, title: String) {
    guard seconds > 0 else { return }
    let content = UNMutableNotificationContent()
    content.title = "Moe’s timer"
    content.body = title
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "moe.timer", content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(seconds), repeats: false))
    UNUserNotificationCenter.current().add(request)
  }
  func cancel() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
      "moe.timer"
    ])
  }
}
struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
@MainActor enum AvatarPixels {
  static func encode(_ image: UIImage) throws -> Data {
    let rendered = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      let scale = max(64 / image.size.width, 64 / image.size.height)
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      image.draw(
        in: CGRect(
          x: (64 - size.width) / 2, y: (64 - size.height) / 2, width: size.width,
          height: size.height))
    }
    guard let cg = rendered.cgImage else { throw PocketError.malformed }
    var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
    guard
      let context = CGContext(
        data: &bytes, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PocketError.malformed }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    var result = Data()
    for n in stride(from: 0, to: bytes.count, by: 4) {
      let pixel =
        (UInt16(bytes[n] >> 3) << 11) | (UInt16(bytes[n + 1] >> 2) << 5) | UInt16(bytes[n + 2] >> 3)
      result.append(UInt8(pixel & 255))
      result.append(UInt8(pixel >> 8))
    }
    return result
  }
}
