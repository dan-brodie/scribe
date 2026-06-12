// SPDX-License-Identifier: MIT

import Foundation

/// Persists per-event "Don't record this meeting" choices.
///
/// Backed by `UserDefaults` (keyed by `calendarItemExternalIdentifier`) so the
/// choice survives relaunches independently of whether a meeting row exists.
struct OptOutStore: Sendable {
    private let defaults: UserDefaults
    private let key = "optedOutEventIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func optedOutIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isOptedOut(_ externalID: String) -> Bool {
        optedOutIDs().contains(externalID)
    }

    func setOptedOut(_ externalID: String, _ optedOut: Bool) {
        var ids = optedOutIDs()
        if optedOut {
            ids.insert(externalID)
        } else {
            ids.remove(externalID)
        }
        defaults.set(Array(ids), forKey: key)
    }
}
