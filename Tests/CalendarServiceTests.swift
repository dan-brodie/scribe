// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class CalendarServiceTests: XCTestCase {
    // MARK: - Helpers

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        externalID: String = "evt",
        title: String? = "Event",
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        startOffset: TimeInterval = 0,
        participants: [ParticipantInfo] = []
    ) -> EventInfo {
        EventInfo(
            externalID: externalID,
            title: title,
            start: start.addingTimeInterval(startOffset),
            end: start.addingTimeInterval(startOffset + 1800),
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            url: url,
            participants: participants
        )
    }

    private func attendee(
        _ status: ParticipantStatus,
        isCurrentUser: Bool = false,
        email: String? = nil
    ) -> ParticipantInfo {
        ParticipantInfo(name: "P", email: email, status: status, isCurrentUser: isCurrentUser)
    }

    // MARK: - Classifier (ADR-004 heuristic)

    func testSoloEventIsNotAMeeting() {
        // No attendees, no conferencing URL.
        XCTAssertFalse(MeetingClassifier.isMeeting(event()))
    }

    func testOnlyCurrentUserAttendeeIsNotAMeeting() {
        let e = event(participants: [attendee(.accepted, isCurrentUser: true)])
        XCTAssertFalse(MeetingClassifier.isMeeting(e))
    }

    func testZoomURLInNotesIsAMeeting() {
        let e = event(notes: "Join: https://zoom.us/j/123456789")
        XCTAssertTrue(MeetingClassifier.isMeeting(e))
    }

    func testTeamsURLInLocationIsAMeeting() {
        let e = event(location: "https://teams.microsoft.com/l/meetup-join/xyz")
        XCTAssertTrue(MeetingClassifier.isMeeting(e))
    }

    func testGoogleMeetURLIsAMeeting() {
        let e = event(url: "https://meet.google.com/abc-defg-hij")
        XCTAssertTrue(MeetingClassifier.isMeeting(e))
    }

    // MARK: - Conference link extraction (meeting prompt)

    func testConferenceURLExtractedFromNotes() {
        let e = event(notes: "Agenda below.\nJoin: https://zoom.us/j/123456789\nThanks")
        XCTAssertEqual(MeetingClassifier.conferenceURL(from: e), "https://zoom.us/j/123456789")
    }

    func testConferenceURLPrefersURLField() {
        let e = event(notes: "https://zoom.us/j/111", url: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingClassifier.conferenceURL(from: e), "https://meet.google.com/abc-defg-hij")
    }

    func testConferenceURLNilWhenNoConferencingLink() {
        let e = event(notes: "See https://example.com/agenda for details")
        XCTAssertNil(MeetingClassifier.conferenceURL(from: e))
    }

    func testEventWithAcceptedAttendeeIsAMeeting() {
        let e = event(participants: [
            attendee(.accepted, isCurrentUser: true),
            attendee(.accepted),
        ])
        XCTAssertTrue(MeetingClassifier.isMeeting(e))
    }

    func testUserDeclinedInviteIsNotAMeeting() {
        // Another attendee accepted, but the user declined → skip.
        let e = event(
            notes: "https://zoom.us/j/999",
            participants: [
                attendee(.declined, isCurrentUser: true),
                attendee(.accepted),
            ]
        )
        XCTAssertFalse(MeetingClassifier.isMeeting(e))
    }

    func testOnlyDeclinedOtherAttendeeIsNotAMeeting() {
        let e = event(participants: [attendee(.declined)])
        XCTAssertFalse(MeetingClassifier.isMeeting(e))
    }

    func testAllDayEventIsNeverAMeeting() {
        let e = event(isAllDay: true, notes: "https://zoom.us/j/1")
        XCTAssertFalse(MeetingClassifier.isMeeting(e))
    }

    func testNonConferencingURLIsNotAMeeting() {
        let e = event(notes: "Agenda at https://example.com/doc")
        XCTAssertFalse(MeetingClassifier.isMeeting(e))
    }

    // MARK: - Recurring dedupe

    func testRecurringMeetingIsDeduplicatedByExternalID() {
        let instances = [
            event(externalID: "series-1", startOffset: 7200, participants: [attendee(.accepted)]),
            event(externalID: "series-1", startOffset: 0, participants: [attendee(.accepted)]),
            event(externalID: "series-1", startOffset: 3600, participants: [attendee(.accepted)]),
            event(externalID: "other", startOffset: 60, participants: [attendee(.accepted)]),
        ]
        let deduped = MeetingClassifier.dedupe(instances)
        XCTAssertEqual(deduped.count, 2)
        // Earliest instance of the series is kept.
        let series = deduped.first { $0.externalID == "series-1" }
        XCTAssertEqual(series?.start, start)
        // Sorted by start ascending.
        XCTAssertEqual(deduped.map(\.externalID), ["series-1", "other"])
    }

    // MARK: - Email extraction

    func testParseMailtoExtractsEmail() {
        XCTAssertEqual(MeetingClassifier.parseMailto("mailto:dan@example.com"), "dan@example.com")
        XCTAssertEqual(MeetingClassifier.parseMailto("MAILTO:Up@Case.com"), "Up@Case.com")
    }

    func testParseMailtoHandlesNilAndNonMailto() {
        XCTAssertNil(MeetingClassifier.parseMailto(nil))
        XCTAssertNil(MeetingClassifier.parseMailto("https://example.com"))
        XCTAssertNil(MeetingClassifier.parseMailto("mailto:"))
    }

    // MARK: - Opt-out persistence

    func testOptOutStoreRoundTrips() throws {
        let suite = "OptOutStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = OptOutStore(defaults: defaults)
        XCTAssertFalse(store.isOptedOut("evt-1"))

        store.setOptedOut("evt-1", true)
        XCTAssertTrue(store.isOptedOut("evt-1"))

        // Survives a fresh store instance (i.e. relaunch).
        let reopened = OptOutStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reopened.isOptedOut("evt-1"))

        store.setOptedOut("evt-1", false)
        XCTAssertFalse(store.isOptedOut("evt-1"))
    }

    // MARK: - Persistence of detected meetings + attendees

    func testUpsertStoresScheduledMeetingWithAttendees() async throws {
        let db = try Database.inMemory()
        let attendees = [
            ParticipantInfo(name: "Dan", email: "dan@example.com", status: .accepted, isCurrentUser: true),
            ParticipantInfo(name: "Sam", email: nil, status: .tentative, isCurrentUser: false),
        ]
        let id = try await db.upsertScheduledMeeting(
            externalID: "ext-1",
            title: "Sync",
            start: start,
            end: start.addingTimeInterval(1800),
            attendees: attendees
        )

        let state = try await db.meetingState(id: id)
        XCTAssertEqual(state, .scheduled)

        let stored = try await db.attendees(forMeeting: id)
        XCTAssertEqual(stored.count, 2)
        let dan = stored.first { $0.name == "Dan" }
        XCTAssertEqual(dan?.email, "dan@example.com")
        XCTAssertEqual(dan?.rsvp, "accepted")
        XCTAssertEqual(dan?.role, "self")
        // Anonymous attendee (nil email) is stored, not dropped.
        let sam = stored.first { $0.name == "Sam" }
        XCTAssertNil(sam?.email)
        XCTAssertEqual(sam?.rsvp, "tentative")
    }

    func testUpsertReplacesAttendeesAndKeepsState() async throws {
        let db = try Database.inMemory()
        let id = try await db.upsertScheduledMeeting(
            externalID: "ext-2",
            title: "Original",
            start: start,
            end: start.addingTimeInterval(1800),
            attendees: [ParticipantInfo(name: "A", email: nil, status: .accepted, isCurrentUser: false)]
        )

        // Advance the meeting beyond `scheduled`; a re-sync must not reset it.
        let sm = StateMachine(database: db)
        try await sm.transition(meeting: id, to: .recorded)

        let id2 = try await db.upsertScheduledMeeting(
            externalID: "ext-2",
            title: "Updated",
            start: start,
            end: start.addingTimeInterval(3600),
            attendees: [
                ParticipantInfo(name: "B", email: "b@x.com", status: .declined, isCurrentUser: false),
                ParticipantInfo(name: "C", email: nil, status: .accepted, isCurrentUser: false),
            ]
        )
        XCTAssertEqual(id, id2, "same external ID should map to the same row")

        let state = try await db.meetingState(id: id)
        XCTAssertEqual(state, .recorded, "re-sync must preserve pipeline state")

        let stored = try await db.attendees(forMeeting: id)
        XCTAssertEqual(Set(stored.map(\.name)), ["B", "C"], "attendees fully replaced")
    }
}
