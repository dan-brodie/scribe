// SPDX-License-Identifier: MIT

import EventKit
import Foundation

/// A calendar the user can choose to watch (Settings picker).
struct CalendarInfo: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var source: String
}

/// A detected upcoming meeting, surfaced to the UI and persisted.
struct UpcomingMeeting: Identifiable, Sendable, Equatable {
    var externalID: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [ParticipantInfo]
    var optedOut: Bool

    var id: String { externalID }
}

/// Owns the `EKEventStore`, fetches upcoming events, classifies them, and
/// persists detected meetings + attendees. An `actor` so polling and on-change
/// refreshes never race.
actor CalendarService {
    private let store = EKEventStore()
    private let database: Database
    private let optOutStore: OptOutStore
    private let defaults: UserDefaults
    private let watchedKey = "watchedCalendarIDs"
    private let logger = Log.make("CalendarService")

    init(database: Database, optOutStore: OptOutStore = OptOutStore(), defaults: UserDefaults = .standard) {
        self.database = database
        self.optOutStore = optOutStore
        self.defaults = defaults
    }

    // MARK: - Authorization

    nonisolated var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    nonisolated var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            logger.info("calendar access granted=\(granted, privacy: .public)")
            return granted
        } catch {
            logger.error("calendar access request failed: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Calendar selection

    func availableCalendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// `nil` means "all calendars".
    var watchedCalendarIDs: Set<String>? {
        guard let ids = defaults.stringArray(forKey: watchedKey), !ids.isEmpty else { return nil }
        return Set(ids)
    }

    func setWatchedCalendars(_ ids: Set<String>?) {
        if let ids, !ids.isEmpty {
            defaults.set(Array(ids), forKey: watchedKey)
        } else {
            defaults.removeObject(forKey: watchedKey)
        }
    }

    private func selectedCalendars() -> [EKCalendar]? {
        guard let watched = watchedCalendarIDs else { return nil }
        return store.calendars(for: .event).filter { watched.contains($0.calendarIdentifier) }
    }

    // MARK: - Opt-out

    func setOptOut(_ externalID: String, _ optedOut: Bool) {
        optOutStore.setOptedOut(externalID, optedOut)
    }

    // MARK: - Fetch

    /// Fetch, classify, dedupe, and persist upcoming meetings within `hours`.
    /// Returns them sorted by start ascending. Opted-out meetings are still
    /// returned (flagged) so the UI can show their status.
    func upcomingMeetings(within hours: Int = 24, now: Date = Date()) async -> [UpcomingMeeting] {
        guard isAuthorized else { return [] }
        guard let end = Calendar.current.date(byAdding: .hour, value: hours, to: now) else { return [] }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: selectedCalendars())
        let infos = store.events(matching: predicate).map(Self.eventInfo(from:))
        let meetings = MeetingClassifier.dedupe(infos.filter(MeetingClassifier.isMeeting))

        var result: [UpcomingMeeting] = []
        for info in meetings where info.end > now {
            let title = info.title?.isEmpty == false ? info.title! : "(No title)"
            let meeting = UpcomingMeeting(
                externalID: info.externalID,
                title: title,
                start: info.start,
                end: info.end,
                attendees: info.participants,
                optedOut: optOutStore.isOptedOut(info.externalID)
            )
            result.append(meeting)

            do {
                try await database.upsertScheduledMeeting(
                    externalID: info.externalID,
                    title: title,
                    start: info.start,
                    end: info.end,
                    attendees: info.participants
                )
            } catch {
                logger.error("failed to persist meeting \(info.externalID, privacy: .public): \(error, privacy: .public)")
            }
        }
        logger.info("found \(result.count, privacy: .public) upcoming meeting(s)")
        return result
    }

    // MARK: - EKEvent bridge

    nonisolated static func eventInfo(from event: EKEvent) -> EventInfo {
        EventInfo(
            externalID: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            participants: (event.attendees ?? []).map(participantInfo(from:))
        )
    }

    nonisolated static func participantInfo(from participant: EKParticipant) -> ParticipantInfo {
        ParticipantInfo(
            name: participant.name,
            email: MeetingClassifier.parseMailto(participant.url.absoluteString),
            status: participantStatus(from: participant.participantStatus),
            isCurrentUser: participant.isCurrentUser
        )
    }

    nonisolated static func participantStatus(from status: EKParticipantStatus) -> ParticipantStatus {
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        default: return .unknown
        }
    }
}
