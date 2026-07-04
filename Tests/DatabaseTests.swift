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

    func testRecurringOccurrencesGetSeparateMeetingRows() async throws {
        // A recurring series shares one calendarItemExternalIdentifier; keying
        // rows on the occurrence ID keeps each instance's pipeline independent
        // (the H1 fix — previously the second occurrence collided with the
        // first's terminal `exported` state and was never processed).
        let db = try Database.inMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400

        let first = try await db.upsertScheduledMeeting(
            externalID: UpcomingMeeting.occurrenceID(externalID: "series-1", start: start),
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(1800),
            attendees: []
        )
        let second = try await db.upsertScheduledMeeting(
            externalID: UpcomingMeeting.occurrenceID(externalID: "series-1", start: start.addingTimeInterval(day)),
            title: "Standup",
            start: start.addingTimeInterval(day),
            end: start.addingTimeInterval(day + 1800),
            attendees: []
        )

        XCTAssertNotEqual(first, second, "each occurrence gets its own row")

        // Completing the first occurrence must not block the second.
        let sm = StateMachine(database: db)
        for state in [MeetingState.recorded, .transcribed, .diarized, .summarized, .exported] {
            try await sm.transition(meeting: first, to: state)
        }
        try await sm.transition(meeting: second, to: .recorded)
        let secondState = try await db.meetingState(id: second)
        XCTAssertEqual(secondState, .recorded)
    }

    func testIncompleteMeetingsReturnsOnlyMidPipelineStates() async throws {
        let db = try Database.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        func makeMeeting(_ eventID: String, _ state: MeetingState, offset: TimeInterval) -> Meeting {
            Meeting(
                id: nil,
                eventID: eventID,
                title: "M",
                start: base.addingTimeInterval(offset),
                end: base.addingTimeInterval(offset + 60),
                state: state,
                exportPath: nil,
                error: nil
            )
        }

        try await db.insert(makeMeeting("evt-scheduled", .scheduled, offset: 0))
        try await db.insert(makeMeeting("evt-recorded", .recorded, offset: 300))
        try await db.insert(makeMeeting("evt-diarized", .diarized, offset: 100))
        try await db.insert(makeMeeting("evt-exported", .exported, offset: 200))

        let incomplete = try await db.incompleteMeetings()
        XCTAssertEqual(
            incomplete.map(\.eventID),
            ["evt-diarized", "evt-recorded"],
            "mid-pipeline meetings only, ordered by start"
        )
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
