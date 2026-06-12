// SPDX-License-Identifier: MIT

import os

/// Central factory for `os.Logger` instances.
///
/// Every service logs under the shared `com.scribe` subsystem with its own
/// category label so logs can be filtered per-component in Console.app.
enum Log {
    static let subsystem = "com.scribe"

    static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
