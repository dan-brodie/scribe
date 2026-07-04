// SPDX-License-Identifier: MIT

import Foundation

/// An attendee's RSVP status, mirrored from `EKParticipantStatus` so the
/// classifier stays free of EventKit and is unit-testable.
enum ParticipantStatus: String, Sendable, Equatable {
    case accepted
    case declined
    case tentative
    case unknown
}

/// A calendar participant, decoupled from `EKParticipant`.
struct ParticipantInfo: Sendable, Equatable {
    var name: String?
    var email: String?
    var status: ParticipantStatus
    var isCurrentUser: Bool

    init(name: String?, email: String?, status: ParticipantStatus, isCurrentUser: Bool) {
        self.name = name
        self.email = email
        self.status = status
        self.isCurrentUser = isCurrentUser
    }
}

/// A calendar event reduced to the fields the classifier needs. Built from
/// `EKEvent` in `CalendarService`; constructed directly in tests.
struct EventInfo: Sendable, Equatable {
    var externalID: String
    var title: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var participants: [ParticipantInfo]

    init(
        externalID: String,
        title: String?,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        participants: [ParticipantInfo] = []
    ) {
        self.externalID = externalID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.participants = participants
    }
}

/// Decides whether a calendar event is a "meeting" Scribe should record, per
/// ADR-004's heuristic.
enum MeetingClassifier {
    /// Conferencing-link regexes (Zoom, Google Meet, Teams, Webex).
    static let conferencingPatterns = [
        #"zoom\.us/j/"#,
        #"meet\.google\.com/"#,
        #"teams\.microsoft\.com/"#,
        #"webex\.com/meet"#,
    ]

    /// An event is a meeting if it has at least one non-declined attendee other
    /// than the user, *or* carries a conferencing URL — and the user has not
    /// declined it. All-day events are never meetings.
    static func isMeeting(_ event: EventInfo) -> Bool {
        guard !event.isAllDay else { return false }

        let hasOtherAttendee = event.participants.contains { participant in
            !participant.isCurrentUser && participant.status != .declined
        }
        guard hasOtherAttendee || hasConferencingURL(event) else { return false }

        let userStatus = event.participants.first { $0.isCurrentUser }?.status
        return userStatus != .declined
    }

    static func hasConferencingURL(_ event: EventInfo) -> Bool {
        let haystack = [event.location, event.notes, event.url]
            .compactMap { $0 }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return conferencingPatterns.contains { pattern in
            haystack.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Hosts trusted for the one-click "Join and transcribe" action. Matched by
    /// exact host or subdomain — never by substring, so a link like
    /// `https://evil.com/zoom.us/j/x` can't qualify.
    static let trustedConferenceHosts = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
    ]

    /// Whether `url` is safe to open from the meeting prompt: `https` and a
    /// trusted conferencing host (or subdomain). Event notes/location are
    /// controlled by the meeting's inviter, so this is a security boundary —
    /// the loose regex classification above must never decide what gets opened.
    static func isTrustedConferenceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return trustedConferenceHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The first conferencing link in the event (URL field, then location, then
    /// notes), or `nil`. Used to surface a join link in the meeting prompt —
    /// only https links on trusted conferencing hosts qualify.
    static func conferenceURL(from event: EventInfo) -> String? {
        let haystack = [event.url, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: "\n")
        guard !haystack.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        for match in detector.matches(in: haystack, range: range) {
            guard let url = match.url else { continue }
            if isTrustedConferenceURL(url) {
                return url.absoluteString
            }
        }
        return nil
    }

    /// Collapse recurring-series duplicates: keep the earliest instance per
    /// `externalID` (`calendarItemExternalIdentifier`). Result is sorted by
    /// start ascending.
    static func dedupe(_ events: [EventInfo]) -> [EventInfo] {
        let sorted = events.sorted { $0.start < $1.start }
        var seen = Set<String>()
        var result: [EventInfo] = []
        for event in sorted where seen.insert(event.externalID).inserted {
            result.append(event)
        }
        return result
    }

    /// Extract an email address from a `mailto:` URL string, or `nil`. Any
    /// header query (`?subject=…`) is dropped — only the address part is kept.
    static func parseMailto(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let prefix = "mailto:"
        guard raw.lowercased().hasPrefix(prefix) else { return nil }
        let email = String(raw.dropFirst(prefix.count)).components(separatedBy: "?")[0]
        return email.isEmpty ? nil : email
    }
}
