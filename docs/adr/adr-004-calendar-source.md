# ADR-004: Calendar Source — EventKit First

## Status
Accepted

## Context
Two paths exist for reading Google Calendar:
1. **EventKit** — if the user's Google account is in macOS System Settings → Internet Accounts, EventKit exposes it locally with no OAuth
2. **Google Calendar API** — direct OAuth2, richer conferencing metadata (`conferenceData`), but adds OAuth complexity and token storage

## Decision
v1 uses **EventKit** (`NSCalendarsFullAccessUsageDescription`).

Meeting detection heuristic: an event is a "meeting" if:
- It has ≥1 attendee other than the user, OR
- Its title/location/notes contain a conferencing URL (Zoom, Meet, Teams, Webex regexes)
- AND the user hasn't declined it

Direct Google Calendar API connector is a Phase-7 stretch goal for users who refuse to add the account to macOS.

## Consequences
- No OAuth, no token storage, no API quotas
- `EKParticipant.url` (mailto:) gives attendee emails
- `EKEventStoreChanged` notification used for live refresh
- Limitation: `EKParticipant` emails sometimes nil for external attendees — handle gracefully
