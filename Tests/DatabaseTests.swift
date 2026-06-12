// SPDX-License-Identifier: MIT

import GRDB
import XCTest
@testable import Scribe

final class DatabaseTests: XCTestCase {
    func testMigrationCreatesAllTables() async throws {
        let db = try Database.inMemory()
        let tables = try await db.dbQueue.read { dbConn -> Set<String> in
            let names = try String.fetchAll(
                dbConn,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            return Set(names)
        }
        for expected in ["meetings", "attendees", "speakers", "actions", "voiceProfiles"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testMeetingRoundTrip() async throws {
        let db = try Database.inMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try await db.insert(
            Meeting(
                id: nil,
                eventID: "evt-1",
                title: "Weekly Sync",
                start: start,
                end: start.addingTimeInterval(3600),
                state: .recorded,
                exportPath: nil,
                error: nil
            )
        )
        XCTAssertGreaterThan(id, 0)

        let fetched = try await db.dbQueue.read { dbConn in
            try Meeting.fetchOne(dbConn, id: id)
        }
        XCTAssertEqual(fetched?.eventID, "evt-1")
        XCTAssertEqual(fetched?.title, "Weekly Sync")
        XCTAssertEqual(fetched?.state, .recorded)
        XCTAssertEqual(fetched?.start, start)
    }

    func testAttendeeForeignKeyCascades() async throws {
        let db = try Database.inMemory()
        let meetingID = try await db.insert(
            Meeting(
                id: nil,
                eventID: "evt-cascade",
                title: "M",
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 60),
                state: .recorded,
                exportPath: nil,
                error: nil
            )
        )

        try await db.dbQueue.write { dbConn in
            var attendee = Attendee(
                id: nil,
                meetingID: meetingID,
                name: "Dan",
                email: "dan@example.com",
                role: "organizer",
                rsvp: "accepted"
            )
            try attendee.insert(dbConn)
        }

        // Deleting the meeting cascades to its attendees.
        try await db.dbQueue.write { dbConn in
            _ = try Meeting.deleteOne(dbConn, id: meetingID)
        }

        let remaining = try await db.dbQueue.read { dbConn in
            try Attendee.fetchCount(dbConn)
        }
        XCTAssertEqual(remaining, 0)
    }

    func testStateColumnDefaultsToRecorded() async throws {
        let db = try Database.inMemory()
        let state = try await db.dbQueue.write { dbConn -> String in
            try dbConn.execute(
                sql: """
                INSERT INTO meetings (eventID, title, start, end)
                VALUES ('evt-default', 'T', '2026-01-01', '2026-01-01')
                """
            )
            return try String.fetchOne(dbConn, sql: "SELECT state FROM meetings LIMIT 1") ?? ""
        }
        XCTAssertEqual(state, MeetingState.recorded.rawValue)
    }
}
