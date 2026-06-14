// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// A calendar meeting and its position in the processing pipeline.
struct Meeting: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var eventID: String
    var title: String
    var start: Date
    var end: Date
    var state: MeetingState
    var exportPath: String?
    var error: String?

    static let databaseTableName = "meetings"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
