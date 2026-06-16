// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Settings window. Phase 1 adds calendar access + a calendar picker; folders,
/// models, and auto-record policy arrive in later phases.
struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    /// IDs of calendars currently selected to watch. Empty == none; when every
    /// available calendar is selected we persist "watch all" (nil).
    @State private var selected: Set<String> = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Calendar Access") {
                if coordinator.calendarAuthorized {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Scribe needs calendar access to detect your meetings.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Grant Calendar Access…") {
                            Task { await coordinator.grantCalendarAccess() }
                        }
                        Button("Open System Settings") {
                            openCalendarPrivacySettings()
                        }
                        .buttonStyle(.link)
                    }
                    // macOS only shows the access prompt once. If it was previously
                    // dismissed or denied, the Grant button silently no-ops — use
                    // System Settings to enable access manually.
                    Text("If the button above does nothing, calendar access was previously denied — enable it in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notes Folder") {
                HStack {
                    Text(coordinator.outputFolderDisplayPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { coordinator.chooseOutputFolder() }
                    Button("Reveal") { coordinator.revealOutputFolder() }
                }
                Text("Meeting notes are written here, one folder per meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Picker("When a meeting starts", selection: $coordinator.recordMode) {
                    ForEach(RecordMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(recordModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if coordinator.recordMode != .off && !coordinator.hasAcknowledgedConsent {
                    Label(
                        "Recording is paused until you acknowledge the consent notice in onboarding.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Sharing") {
                Toggle("Attach full transcript to shared email", isOn: $coordinator.includeTranscriptInEmail)
                Text("Off by default — the email contains the summary and action items only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Summarization") {
                Picker("Engine", selection: $coordinator.summarizationBackend) {
                    ForEach(SummarizationBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                if coordinator.summarizationBackend == .appleFoundationModels
                    && !coordinator.appleFoundationModelsAvailable {
                    Label(
                        "Apple Intelligence isn't available on this Mac — Scribe will use the downloadable Gemma model instead.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Apple runs fully on-device with no download. Gemma runs on-device too but downloads a ~2.5 GB model on first use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speakers") {
                Toggle("Remember voices", isOn: $coordinator.rememberVoices)
                Text("Recognize recurring speakers across meetings by their voice. Stored on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Voice Profiles", role: .destructive) {
                    Task { await coordinator.deleteVoiceProfiles() }
                }
            }

            if coordinator.calendarAuthorized {
                Section("Watched Calendars") {
                    if coordinator.availableCalendars.isEmpty {
                        Text("No calendars found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.availableCalendars) { calendar in
                            Toggle(isOn: binding(for: calendar.id)) {
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                    Text(calendar.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .navigationTitle("Scribe Settings")
        .task {
            guard !loaded else { return }
            let watched = await coordinator.watchedCalendarIDs()
            // nil means "watch all" — reflect that as every calendar selected.
            selected = watched ?? Set(coordinator.availableCalendars.map(\.id))
            loaded = true
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
                persistSelection()
            }
        )
    }

    private var recordModeHint: String {
        switch coordinator.recordMode {
        case .off: return "Scribe won't record meetings automatically — use “Record Now” from the menu."
        case .ask: return "Scribe shows a “Take Notes / Ignore” notification when a meeting starts."
        case .auto: return "Scribe starts recording automatically when a meeting starts."
        }
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func persistSelection() {
        let allIDs = Set(coordinator.availableCalendars.map(\.id))
        // Watching every calendar is stored as "all" (nil) so newly-added
        // calendars are included automatically.
        let value: Set<String>? = selected == allIDs ? nil : selected
        Task { await coordinator.setWatchedCalendars(value) }
    }
}
