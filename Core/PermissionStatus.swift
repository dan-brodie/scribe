// SPDX-License-Identifier: MIT

import Foundation

/// Simplified TCC permission state for the Settings permissions overview.
enum PermissionStatus: Sendable {
    case granted
    case denied
    case unknown  // not yet determined, or (system audio) not yet probed

    var isGranted: Bool { self == .granted }
}
