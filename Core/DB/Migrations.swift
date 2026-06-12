// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// All schema migrations, in registration order.
///
/// Migrations are append-only: never edit an existing one once shipped — add a
/// new `vN` step instead.
enum Migrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-initial-schema") { db in
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("eventID", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("start", .datetime).notNull()
                t.column("end", .datetime).notNull()
                t.column("state", .text).notNull().defaults(to: MeetingState.recorded.rawValue)
                t.column("exportPath", .text)
                t.column("error", .text)
            }

            try db.create(table: "attendees") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingID", .integer)
                    .notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("role", .text)
                t.column("rsvp", .text)
            }

            try db.create(table: "speakers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingID", .integer)
                    .notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("assignedAttendee", .text)
                t.column("confidence", .double)
                t.column("provenance", .text)
            }

            try db.create(table: "actions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingID", .integer)
                    .notNull()
                    .indexed()
                    .references("meetings", onDelete: .cascade)
                t.column("owner", .text)
                t.column("task", .text).notNull()
                t.column("due", .datetime)
                t.column("done", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "voiceProfiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personEmail", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("embeddingBlob", .blob).notNull()
                t.column("sampleCount", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
