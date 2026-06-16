// SPDX-License-Identifier: MIT

import Foundation

/// What Scribe does when a watched meeting is about to start.
///
/// - `off`: do nothing (fully manual via "Record Now").
/// - `ask`: post a "Take Notes / Ignore" notification (the consent-safer default).
/// - `auto`: start recording silently at the meeting's start.
enum RecordMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case ask
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Do nothing"
        case .ask: return "Ask me"
        case .auto: return "Record automatically"
        }
    }
}
