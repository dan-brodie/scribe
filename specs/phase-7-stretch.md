# Phase 7 — Stretch Goals

status: not-started

## Goal

Post-v1 enhancements: Apple Notes export, Google Calendar API connector, PDF export, live caption window.

## Items (not ordered)

### 7a — Apple Notes Export (AppleScript)
- Write `notes.txt` content into a new Note via AppleScript/Apple Events
- Requires entitlement: `com.apple.security.automation.apple-events`
- Adds "Control Notes" consent prompt on first use
- Implementation: `NSAppleScript` or `OSAKit` — project the already-canonical output files into a Note

### 7b — Google Calendar API Connector
- OAuth2 flow for users who don't add their Google account to macOS Internet Accounts
- `calendar.readonly` scope; richer `conferenceData` (Meet links)
- Token stored in Keychain; refresh handled transparently
- Fallback to EventKit if available

### 7c — PDF Export
- Generate a PDF version of `notes.txt` using `NSAttributedString` → `NSPrintOperation`
- Attach to share email (P1 in Phase 6)

### 7d — Live Caption Window
- Real-time transcript display during recording using `StreamingEouAsrManager`
- Floating `NSPanel` (non-activating) positioned near the menu bar
- Toggle in Settings; off by default (adds GPU/ANE load during recording)

### 7e — Menu-Bar Mini Transcript
- Last 3 speaker turns shown in the menu when recording
- Driven by the streaming ASR feed from 7d

## Dependencies

- 7a requires 7 (none) but adds an entitlement — assess App Store impact
- 7b can be done independently of 7a
- 7d requires the streaming ASR path from Phase 3 to be implemented (if batch was chosen)
