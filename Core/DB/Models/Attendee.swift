// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// A person invited to a meeting, sourced from the calendar event.
struct Attendee: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var meetingID: Int64
    var name: String
    var email: String?
    var role: String?
    var rsvp: String?

    static let databaseTableName = "attendees"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
