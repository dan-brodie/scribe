// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import UserNotifications

/// Bridges notification interactions to Finder. Lives apart from
/// `AppCoordinator` so the coordinator can stay a plain `@Observable` class
/// rather than an `NSObject` subclass: `UNUserNotificationCenterDelegate`
/// requires `NSObject`.
///
/// The export notification carries its folder path in `userInfo`, so tapping the
/// banner — or its "Reveal in Finder" action — reveals the notes without any
/// coordinator round-trip.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionHandler()

    static let exportCategoryID = "EXPORT_DONE"
    static let revealActionID = "REVEAL_IN_FINDER"
    static let pathKey = "exportPath"

    /// Register the export category + reveal action and install ourselves as the
    /// notification-center delegate. Idempotent.
    func register() {
        let reveal = UNNotificationAction(
            identifier: Self.revealActionID,
            title: "Reveal in Finder",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.exportCategoryID,
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let revealRequested = action == Self.revealActionID || action == UNNotificationDefaultActionIdentifier
        if revealRequested,
           let path = response.notification.request.content.userInfo[Self.pathKey] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    /// Show export banners even while Scribe is the foreground app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
