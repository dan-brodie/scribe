// SPDX-License-Identifier: MIT

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
                    Button("Grant Calendar Access…") {
                        Task { await coordinator.grantCalendarAccess() }
                    }
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
        .frame(width: 420, height: 360)
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

    private func persistSelection() {
        let allIDs = Set(coordinator.availableCalendars.map(\.id))
        // Watching every calendar is stored as "all" (nil) so newly-added
        // calendars are included automatically.
        let value: Set<String>? = selected == allIDs ? nil : selected
        Task { await coordinator.setWatchedCalendars(value) }
    }
}
