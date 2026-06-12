# ADR-006: Sharing — Email Draft, Never Silent Send

## Status
Accepted

## Context
Options considered:
- Apple Notes collaboration (iCloud share links) — cannot be automated via AppleScript
- Direct email send via SMTP — would require credentials; legally risky (silent recording + silent send)
- `mailto:` draft via `NSSharingService` — user always reviews before sending

## Decision
"Share with attendees" composes a pre-filled email via `NSSharingService`/`mailto:`:
- **To:** attendee emails from the calendar invite
- **Subject:** `Notes: <title> (<date>)`
- **Body:** summary + action items
- **Attachment:** `transcript.txt` optional (off by default, P1 toggle)

The user **always reviews and presses Send**. Nothing is ever sent automatically.

## Consequences
- Respects two-party consent laws (recording is on the user; distribution is the user's explicit act)
- No SMTP credentials or OAuth required
- Opens in the user's default mail client — works with any mail app
- Limitation: `mailto:` body length limits exist in some clients; truncate gracefully
