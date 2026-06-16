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
/// The user's response to a "meeting is starting" prompt.
enum MeetingPromptDecision: Sendable {
    case takeNotes
    case ignore
}

final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionHandler()

    static let exportCategoryID = "EXPORT_DONE"
    static let revealActionID = "REVEAL_IN_FINDER"
    static let pathKey = "exportPath"

    static let meetingPromptCategoryID = "MEETING_PROMPT"
    static let takeNotesActionID = "TAKE_NOTES"
    static let ignoreActionID = "IGNORE_MEETING"
    static let eventIDKey = "eventID"
    static let meetingURLKey = "meetingURL"

    /// Invoked when the user responds to a meeting prompt (set by AppCoordinator).
    var onMeetingPrompt: (@Sendable (String, MeetingPromptDecision) -> Void)?

    /// Register notification categories + actions and install ourselves as the
    /// notification-center delegate. Idempotent.
    func register() {
        let reveal = UNNotificationAction(
            identifier: Self.revealActionID,
            title: "Reveal in Finder",
            options: [.foreground]
        )
        let exportCategory = UNNotificationCategory(
            identifier: Self.exportCategoryID,
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )

        let takeNotes = UNNotificationAction(
            identifier: Self.takeNotesActionID,
            title: "Take Notes",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionID,
            title: "Ignore",
            options: []
        )
        let meetingPromptCategory = UNNotificationCategory(
            identifier: Self.meetingPromptCategoryID,
            actions: [takeNotes, ignore],
            intentIdentifiers: [],
            options: []
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([exportCategory, meetingPromptCategory])
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier

        if category == Self.meetingPromptCategoryID {
            handleMeetingPrompt(action: action, userInfo: userInfo)
            completionHandler()
            return
        }

        let revealRequested = action == Self.revealActionID || action == UNNotificationDefaultActionIdentifier
        if revealRequested,
           let path = userInfo[Self.pathKey] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    /// Route a meeting-prompt response: explicit actions go to the coordinator;
    /// tapping the banner body opens the meeting link (join the call).
    private func handleMeetingPrompt(action: String, userInfo: [AnyHashable: Any]) {
        guard let eventID = userInfo[Self.eventIDKey] as? String else { return }
        switch action {
        case Self.takeNotesActionID:
            onMeetingPrompt?(eventID, .takeNotes)
        case Self.ignoreActionID:
            onMeetingPrompt?(eventID, .ignore)
        case UNNotificationDefaultActionIdentifier:
            if let link = userInfo[Self.meetingURLKey] as? String,
               !link.isEmpty, let url = URL(string: link) {
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        default:
            break
        }
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
