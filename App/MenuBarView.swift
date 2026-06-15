// SPDX-License-Identifier: MIT

import ServiceManagement
import SwiftUI

/// Contents of the menu bar dropdown. A thin view: all state lives in
/// `AppCoordinator` and `LaunchAtLogin`.
struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @Environment(\.openWindow) private var openWindow

    private let logger = Log.make("MenuBarView")

    var body: some View {
        Group {
            Label("Scribe — \(coordinator.status.label)", systemImage: coordinator.status.symbolName)
                .labelStyle(.titleAndIcon)

            if let progress = coordinator.modelDownloadProgress {
                Text("Downloading model… \(Int(progress * 100))%")
                    .font(.caption)
            } else if let message = coordinator.processingMessage {
                Text(message)
                    .font(.caption)
            }

            Divider()

            nextMeetingSection

            Divider()

            recordingSection

            if let meetingID = coordinator.lastDiarizedMeetingID {
                Button("Review Speakers…") {
                    openWindow(id: "review", value: meetingID)
                }
            }

            if let meetingID = coordinator.lastExportedMeetingID {
                Button("Reveal Last Notes in Finder") {
                    Task { await coordinator.revealExport(meetingID: meetingID) }
                }
                Button("Share Last Notes…") {
                    Task { await coordinator.shareNotes(meetingID: meetingID) }
                }
            }

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit Scribe") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        if coordinator.isRecording {
            Button("Stop Recording") {
                Task { await coordinator.stopRecording() }
            }
            Button("Discard Recording") {
                Task { await coordinator.discardRecording() }
            }
        } else if coordinator.microphoneAccessDenied {
            Button("Enable Microphone Access…") {
                coordinator.openMicrophoneSettings()
            }
        } else {
            Button("Record Now") {
                Task { await coordinator.recordNow() }
            }
        }
    }

    @ViewBuilder
    private var nextMeetingSection: some View {
        if !coordinator.calendarAuthorized {
            Button("Grant Calendar Access…") {
                Task { await coordinator.grantCalendarAccess() }
            }
        } else if let meeting = coordinator.nextMeeting {
            // SwiftUI keeps a relative-time label live in the menu.
            Text("Next: \(meeting.title)")
            Text(meeting.start, style: .relative)
                .font(.caption)

            Toggle("Don't record this meeting", isOn: optOutBinding(for: meeting))
        } else {
            Text("No upcoming meetings")
                .foregroundStyle(.secondary)
        }
    }

    private func optOutBinding(for meeting: UpcomingMeeting) -> Binding<Bool> {
        Binding(
            get: { meeting.optedOut },
            set: { newValue in
                Task { await coordinator.setOptOut(meeting, optedOut: newValue) }
            }
        )
    }
}

/// Wrapper around `SMAppService.mainApp` for the launch-at-login toggle.
enum LaunchAtLogin {
    private static let logger = Log.make("LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logger.info("launch at login set to \(enabled, privacy: .public)")
        } catch {
            logger.error("failed to set launch at login: \(error, privacy: .public)")
        }
    }
}
