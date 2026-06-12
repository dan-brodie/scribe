# EventKit — Local API Reference

**Framework:** EventKit (built-in, macOS 10.8+)
**Import:** `import EventKit`

## Permission

```xml
<!-- Info.plist -->
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Scribe needs access to your calendar to detect and prepare for upcoming meetings.</string>
```

```swift
let store = EKEventStore()
try await store.requestFullAccessToEvents()
// or with completion handler on older OS:
store.requestFullAccessToEvents { granted, error in ... }
```

## Fetch Upcoming Events

```swift
let now = Date()
let tomorrow = Calendar.current.date(byAdding: .hour, value: 24, to: now)!
let predicate = store.predicateForEvents(withStart: now, end: tomorrow, calendars: nil)
let events = store.events(matching: predicate)
// Returns [EKEvent], sorted by start date
```

## Key EKEvent Properties

```swift
event.eventIdentifier    // String — stable across recurring instances? No. Use externalIdentifier.
event.title              // String?
event.startDate          // Date
event.endDate            // Date
event.attendees          // [EKParticipant]?
event.organizer          // EKParticipant?
event.location           // String?  — may contain Meet/Zoom link
event.notes              // String?  — may contain conferencing URL
event.url                // URL?
event.isAllDay           // Bool
event.calendar           // EKCalendar
```

## Attendee Properties

```swift
participant.name                  // String?
participant.url                   // URL?  — "mailto:name@example.com"
participant.participantStatus     // .accepted / .declined / .tentative / .unknown
participant.participantRole       // .chair / .required / .optional / .unknown
participant.isCurrentUser         // Bool
```

Extract email from `participant.url`:
```swift
let email = participant.url?.absoluteString
    .replacingOccurrences(of: "mailto:", with: "")
```

## Meeting Detection Heuristic

```swift
func isMeeting(_ event: EKEvent) -> Bool {
    guard !event.isAllDay else { return false }
    guard event.attendees?.contains(where: { $0.participantStatus != .declined }) == true
       || hasConferencingURL(event) else { return false }
    // User hasn't declined
    let userStatus = event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus
    return userStatus != .declined
}

let conferencingPatterns = [
    #"zoom\.us/j/"#,
    #"meet\.google\.com/"#,
    #"teams\.microsoft\.com/"#,
    #"webex\.com/meet"#
]

func hasConferencingURL(_ event: EKEvent) -> Bool {
    let haystack = [event.location, event.notes, event.url?.absoluteString]
        .compactMap { $0 }.joined(separator: " ")
    return conferencingPatterns.contains { pattern in
        haystack.range(of: pattern, options: .regularExpression) != nil
    }
}
```

## Change Notifications

```swift
NotificationCenter.default.addObserver(
    forName: .EKEventStoreChanged,
    object: store,
    queue: .main
) { _ in
    // Re-fetch upcoming events
}
```

## Calendar Filtering (Settings)

```swift
let allCalendars = store.calendars(for: .event)
// Let user select which to watch; store selection in UserDefaults
// Pass selected calendars to predicateForEvents(withStart:end:calendars:)
```

## Per-Event Opt-Out

Store opted-out event IDs in UserDefaults or the SQLite `meetings` table (e.g., `state = "opted-out"`). Check before scheduling a recording.

## Notes

- `EKEvent.eventIdentifier` changes across recurring instances; use `EKEvent.calendarItemExternalIdentifier` for recurring series deduplication
- `EKParticipant.url` (mailto:) is sometimes nil for external guests — handle gracefully in the attendee display
- Polling interval: refresh every 5 min + on `EKEventStoreChanged`
