# Phase 1 — Calendar Integration

status: complete

## Goal

Integrate EventKit so Scribe detects upcoming Google Calendar meetings, extracts attendee data, and shows the next meeting in the menu bar.

## Acceptance Criteria

- [x] EventKit permission is requested via onboarding flow (not a raw system alert)
- [x] `CalendarService` polls upcoming events every 5 min + on `EKEventStoreChanged`
- [x] Meeting classifier correctly identifies meetings per ADR-004 heuristic
- [x] Unit tests for classifier cover: solo event (no attendees, no URL) → not a meeting; Zoom URL in notes → meeting; Teams URL in location → meeting; declined invite → not a meeting; recurring meeting → meeting (deduplicated by `calendarItemExternalIdentifier`)
- [x] Menu bar shows: next meeting title + countdown timer
- [x] Attendees (name, email, RSVP) are extracted and stored in `attendees` table
- [x] Per-event opt-out ("Don't record this meeting") works and persists across relaunches
- [x] Calendar selector in Settings: choose which calendars to watch
- [x] With a Google account in macOS Calendar, the menu shows real upcoming meetings with attendees

## Key Files to Create

```
Services/
  CalendarService.swift     Actor; owns EKEventStore, polling, classifier
App/
  MenuBarView.swift         add "Next meeting: X in Y min" row
  SettingsView.swift        add calendar picker section
Tests/
  CalendarServiceTests.swift   fixture EKEvent mocks, classifier unit tests
```

## Key APIs / Dependencies

- `EventKit` — `EKEventStore`, `EKEvent`, `EKParticipant`
- See `docs/vendor/eventkit.md` for meeting detection heuristic and email extraction
- `NSCalendarsFullAccessUsageDescription` in Info.plist

## Risks

- `EKParticipant.url` is sometimes nil for external guests — treat nil email as anonymous attendee, don't crash
- Recurring event deduplication: use `calendarItemExternalIdentifier`, not `eventIdentifier`
