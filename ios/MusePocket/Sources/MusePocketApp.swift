import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PocketAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    Task { @MainActor in completionHandler() }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping @Sendable (UNNotificationPresentationOptions) -> Void
  ) { completionHandler([.banner, .sound]) }
}
@main struct MusePocketApp: App {
  @UIApplicationDelegateAdaptor(PocketAppDelegate.self) var delegate
  @State private var store = PocketStore()
  var body: some Scene {
    WindowGroup { PocketRootView().environment(store).preferredColorScheme(.dark) }
  }
}
