// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// A diarized speaker label and its (confidence-scored) attendee assignment.
struct Speaker: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var meetingID: Int64
    var label: String
    var assignedAttendee: String?
    var confidence: Double?
    var provenance: String?

    static let databaseTableName = "speakers"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
