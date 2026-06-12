// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// Owns the GRDB `DatabaseQueue` and exposes typed accessors used by the rest
/// of the app. Migrations run at init time.
final class Database: Sendable {
    let dbQueue: DatabaseQueue
    private let logger = Log.make("Database")

    /// Open (or create) the database at `path` and run all pending migrations.
    /// Pass `nil` for an in-memory database (tests).
    init(path: String?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Migrations.makeMigrator().migrate(dbQueue)
        logger.info("database ready at \(path ?? "<in-memory>", privacy: .public)")
    }

    /// The on-disk location: `~/Library/Application Support/Scribe/db.sqlite`.
    static func defaultURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Scribe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("db.sqlite", isDirectory: false)
    }

    /// The production database under Application Support.
    static func makeDefault() throws -> Database {
        try Database(path: defaultURL().path)
    }

    /// An ephemeral in-memory database, for tests and fallback.
    static func inMemory() throws -> Database {
        try Database(path: nil)
    }

    // MARK: - Meeting state

    func meetingState(id: Int64) async throws -> MeetingState? {
        try await dbQueue.read { db in
            try Meeting.fetchOne(db, id: id)?.state
        }
    }

    func updateMeetingState(id: Int64, to state: MeetingState) async throws {
        try await dbQueue.write { db in
            guard var meeting = try Meeting.fetchOne(db, id: id) else { return }
            meeting.state = state
            try meeting.update(db)
        }
    }

    @discardableResult
    func insert(_ meeting: Meeting) async throws -> Int64 {
        try await dbQueue.write { db in
            var copy = meeting
            try copy.insert(db)
            return copy.id ?? 0
        }
    }

    /// Insert or update a calendar-detected meeting (keyed by `eventID` =
    /// `calendarItemExternalIdentifier`) and replace its attendee rows.
    ///
    /// A new meeting is created in the `.scheduled` state; an existing one keeps
    /// its pipeline state and only refreshes calendar-sourced fields.
    @discardableResult
    func upsertScheduledMeeting(
        externalID: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [ParticipantInfo]
    ) async throws -> Int64 {
        try await dbQueue.write { db in
            let existing = try Meeting
                .filter(Column("eventID") == externalID)
                .fetchOne(db)

            let meetingID: Int64
            if var meeting = existing, let id = meeting.id {
                meeting.title = title
                meeting.start = start
                meeting.end = end
                try meeting.update(db)
                meetingID = id
            } else {
                var meeting = Meeting(
                    id: nil,
                    eventID: externalID,
                    title: title,
                    start: start,
                    end: end,
                    state: .scheduled,
                    exportPath: nil,
                    error: nil
                )
                try meeting.insert(db)
                meetingID = meeting.id ?? 0
            }

            try Attendee
                .filter(Column("meetingID") == meetingID)
                .deleteAll(db)
            for participant in attendees {
                var attendee = Attendee(
                    id: nil,
                    meetingID: meetingID,
                    name: participant.name ?? "Unknown",
                    email: participant.email,
                    role: participant.isCurrentUser ? "self" : nil,
                    rsvp: participant.status.rawValue
                )
                try attendee.insert(db)
            }

            return meetingID
        }
    }

    func meeting(id: Int64) async throws -> Meeting? {
        try await dbQueue.read { db in
            try Meeting.fetchOne(db, id: id)
        }
    }

    func setError(meetingID: Int64, message: String) async throws {
        try await dbQueue.write { db in
            guard var meeting = try Meeting.fetchOne(db, id: meetingID) else { return }
            meeting.error = message
            try meeting.update(db)
        }
    }

    func meetingID(forEventID eventID: String) async throws -> Int64? {
        try await dbQueue.read { db in
            try Meeting
                .filter(Column("eventID") == eventID)
                .fetchOne(db)?
                .id
        }
    }

    func attendees(forMeeting meetingID: Int64) async throws -> [Attendee] {
        try await dbQueue.read { db in
            try Attendee
                .filter(Column("meetingID") == meetingID)
                .fetchAll(db)
        }
    }

    // MARK: - Speakers

    /// Replace all speaker rows for a meeting.
    func replaceSpeakers(meetingID: Int64, speakers: [Speaker]) async throws {
        try await dbQueue.write { db in
            try Speaker
                .filter(Column("meetingID") == meetingID)
                .deleteAll(db)
            for speaker in speakers {
                var copy = speaker
                copy.meetingID = meetingID
                try copy.insert(db)
            }
        }
    }

    func speakers(forMeeting meetingID: Int64) async throws -> [Speaker] {
        try await dbQueue.read { db in
            try Speaker
                .filter(Column("meetingID") == meetingID)
                .fetchAll(db)
        }
    }

    /// Reassign a single speaker (used by the Review popover).
    func updateSpeakerAssignment(speakerID: Int64, attendeeEmail: String?, confidence: Double, provenance: String) async throws {
        try await dbQueue.write { db in
            guard var speaker = try Speaker.fetchOne(db, id: speakerID) else { return }
            speaker.assignedAttendee = attendeeEmail
            speaker.confidence = confidence
            speaker.provenance = provenance
            try speaker.update(db)
        }
    }

    // MARK: - Voice profiles

    func upsertVoiceProfile(email: String, name: String, embedding: [Float]) async throws {
        try await dbQueue.write { db in
            let blob = EmbeddingCodec.encode(embedding)
            if var existing = try VoiceProfile.filter(Column("personEmail") == email).fetchOne(db) {
                // Average the new embedding into the stored one.
                let merged = VoiceMath.mean([EmbeddingCodec.decode(existing.embeddingBlob), embedding])
                existing.name = name
                existing.embeddingBlob = merged.isEmpty ? blob : EmbeddingCodec.encode(merged)
                existing.sampleCount += 1
                try existing.update(db)
            } else {
                var profile = VoiceProfile(
                    id: nil,
                    personEmail: email,
                    name: name,
                    embeddingBlob: blob,
                    sampleCount: 1
                )
                try profile.insert(db)
            }
        }
    }

    func allVoiceProfiles() async throws -> [VoiceProfile] {
        try await dbQueue.read { db in
            try VoiceProfile.fetchAll(db)
        }
    }

    func deleteAllVoiceProfiles() async throws {
        _ = try await dbQueue.write { db in
            try VoiceProfile.deleteAll(db)
        }
    }
}
