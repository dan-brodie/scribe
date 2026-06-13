// SPDX-License-Identifier: MIT

import SwiftUI

@main
struct ScribeApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            // The label renders at launch, so this is where one-shot setup runs
            // and the first-launch onboarding window is presented.
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }

        // First-launch onboarding wizard.
        Window("Welcome to Scribe", id: "onboarding") {
            OnboardingView(coordinator: coordinator)
        }
        .windowResizability(.contentSize)

        // Speaker review window, opened from the menu with a meeting id.
        WindowGroup("Review Speakers", id: "review", for: Int64.self) { $meetingID in
            if let meetingID {
                ReviewPopover(coordinator: coordinator, meetingID: meetingID)
            }
        }
    }
}

/// The menu bar icon, plus the launch hook: starts the coordinator and presents
/// onboarding on first run.
private struct MenuBarLabel: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: coordinator.status.symbolName)
            .accessibilityLabel("Scribe — \(coordinator.status.label)")
            .task {
                await coordinator.start()
                if coordinator.needsOnboarding {
                    openWindow(id: "onboarding")
                    // LSUIElement apps don't activate on their own — bring the
                    // onboarding window to the front.
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
