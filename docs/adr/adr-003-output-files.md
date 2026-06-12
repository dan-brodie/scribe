# ADR-003: Output Format — Plain Text Files (Apple Notes Deferred)

## Status
Accepted (v1.1 — Notes dropped from v1.0)

## Context
Original brief included Apple Notes export. Notes has no public API; the only write path is AppleScript/Apple Events, which requires:
- `com.apple.security.automation.apple-events` entitlement
- "Control Notes" consent prompt
- Blocks Mac App Store sandboxing
- Brittle across macOS releases

## Decision
Output is written as plain files to a user-configurable folder (default `~/Documents/Meeting Notes/<YYYY-MM-DD> <title>/`):
- `notes.txt` — summary + decisions + actions + attendees
- `transcript.txt` — speaker-labelled, timestamped segments
- `transcript.json` — machine-readable transcript
- `actions.json` — structured action items `{owner?, task, due?, sourceQuote}`

Files are the canonical store. Apple Notes export is a clean Phase-7 add-on (project existing files into a note).

## Consequences
- No automation entitlement required
- Files are greppable, syncable (iCloud Drive, Dropbox), zero extra permissions
- Speaker-name corrections rewrite files atomically (write-temp-then-rename)
