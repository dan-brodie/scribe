// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// A floating, persistent prompt shown top-center of the screen when a watched
/// meeting starts. Unlike a notification it doesn't auto-dismiss — it stays
/// until the user chooses "Join and transcribe" or "Ignore" — and it floats over
/// other apps (including full-screen meeting windows).
@MainActor
final class MeetingPromptPresenter {
    private var panel: NSPanel?

    func present(
        meeting: UpcomingMeeting,
        onJoin: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        dismiss()

        let view = MeetingPromptView(
            meeting: meeting,
            onJoin: { [weak self] in self?.dismiss(); onJoin() },
            onIgnore: { [weak self] in self?.dismiss(); onIgnore() }
        )

        let hosting = NSHostingView(rootView: view)
        let panel = FloatingPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 16
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A borderless non-activating panel that can still become key so its SwiftUI
/// buttons receive clicks without stealing focus from the meeting app.
private final class FloatingPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The card shown inside the floating prompt.
struct MeetingPromptView: View {
    let meeting: UpcomingMeeting
    let onJoin: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting starting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(timeText, systemImage: "clock")
                if let attendees = attendeesText {
                    Label(attendees, systemImage: "person.2")
                }
                if let provider = providerText {
                    Label(provider, systemImage: "video")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: onIgnore) {
                    Text("Ignore").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button(action: onJoin) {
                    Text("Join and transcribe").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }

    private var timeText: String {
        let time = meeting.start.formatted(date: .omitted, time: .shortened)
        return meeting.start <= Date() ? "Started \(time)" : "Starts \(time)"
    }

    private var attendeesText: String? {
        let others = meeting.attendees.filter { !$0.isCurrentUser }.count
        guard others > 0 else { return nil }
        return others == 1 ? "1 other attendee" : "\(others) attendees"
    }

    /// Friendly conferencing-provider name from the join link, if any.
    private var providerText: String? {
        guard let link = meeting.conferenceURL?.lowercased() else { return nil }
        if link.contains("zoom.us") { return "Zoom" }
        if link.contains("meet.google.com") { return "Google Meet" }
        if link.contains("teams.microsoft.com") { return "Microsoft Teams" }
        if link.contains("webex.com") { return "Webex" }
        return "Join link"
    }
}
