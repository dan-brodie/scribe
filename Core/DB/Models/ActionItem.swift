// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// An action item extracted from a meeting summary.
///
/// Maps to the `actions` table (the type is `ActionItem` to avoid colliding
/// with Swift's `Action`-style naming and stay descriptive).
struct ActionItem: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var meetingID: Int64
    var owner: String?
    var task: String
    var due: Date?
    var done: Bool

    static let databaseTableName = "actions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
