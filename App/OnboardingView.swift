// SPDX-License-Identifier: MIT

import SwiftUI

/// First-launch wizard: the recording-consent notice followed by the three
/// permissions Scribe needs (microphone, system audio, calendar). Each step
/// requests access in-app and offers a deep link to System Settings as a
/// fallback. A thin view — all permission logic lives in `AppCoordinator`.
struct OnboardingView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step = 0
    @State private var micGranted = false
    @State private var systemAudioGranted = false

    private static let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
        }
        .frame(width: 460, height: 380)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            Text("Welcome to Scribe")
                .font(.headline)
            Spacer()
            Text("Step \(step + 1) of \(Self.lastStep + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: consentStep
        case 1: microphoneStep
        case 2: systemAudioStep
        default: calendarStep
        }
    }

    // MARK: - Steps

    private var consentStep: some View {
        stepBody(
            icon: "hand.raised.fill",
            title: "On-device, with your consent",
            detail: "Scribe records meeting audio (your microphone and the audio from your meeting apps), then transcribes and summarizes it entirely on this Mac. Nothing is uploaded — notes are written to a local folder you choose."
        ) {
            Toggle(isOn: consentBinding) {
                Text("I understand Scribe records meeting audio on this Mac.")
            }
            .toggleStyle(.checkbox)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            icon: "mic.fill",
            title: "Microphone",
            detail: "Records your side of the conversation.",
            granted: micGranted,
            settingsAnchor: "Privacy_Microphone"
        ) {
            micGranted = await coordinator.requestMicrophoneAccess()
        }
    }

    private var systemAudioStep: some View {
        permissionStep(
            icon: "speaker.wave.2.fill",
            title: "System Audio Recording",
            detail: "Records the other participants — the audio coming from your meeting app.",
            granted: systemAudioGranted,
            settingsAnchor: "Privacy_AudioCapture"
        ) {
            systemAudioGranted = await coordinator.requestSystemAudioAccess()
        }
    }

    private var calendarStep: some View {
        permissionStep(
            icon: "calendar",
            title: "Calendar",
            detail: "Detects your meetings so recording can start automatically.",
            granted: coordinator.calendarAuthorized,
            settingsAnchor: "Privacy_Calendars"
        ) {
            await coordinator.grantCalendarAccess()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < Self.lastStep {
                Button("Continue") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 0 && !coordinator.hasAcknowledgedConsent)
            } else {
                Button("Finish") {
                    coordinator.completeOnboarding()
                    dismissWindow(id: "onboarding")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Building blocks

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { coordinator.hasAcknowledgedConsent },
            set: { if $0 { coordinator.acknowledgeConsent() } }
        )
    }

    private func permissionStep(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        settingsAnchor: String,
        request: @escaping () async -> Void
    ) -> some View {
        stepBody(icon: icon, title: title, detail: detail) {
            if granted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Button("Grant Access…") {
                        Task { await request() }
                    }
                    Button("Open System Settings") {
                        openPrivacySettings(anchor: settingsAnchor)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func stepBody<Extra: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.title3.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            extra()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
