// SPDX-License-Identifier: MIT

import SwiftUI

@main
struct ScribeApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.status.symbolName)
                .accessibilityLabel("Scribe — \(coordinator.status.label)")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}
