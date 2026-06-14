# Phase 6 — File Export, Sharing, Onboarding, Polish

status: complete

## Goal

Write meeting notes to the output folder atomically, enable share-via-email drafts, complete the onboarding wizard, and wire up the license CI check.

## Acceptance Criteria

- [ ] `FileExporter` writes to `<output folder>/<YYYY-MM-DD> <title>/`: `notes.md`, `transcript.txt`, `transcript.json`, `actions.json`
- [ ] Output folder is user-configurable in Settings (default `~/Documents/Meeting Notes/`); security-scoped bookmark stored if sandboxed
- [ ] Filenames sanitized (no `/`, `:`); collisions suffixed with ` (2)`, ` (3)`, etc.
- [ ] Speaker-name corrections (from Review popover) rewrite files atomically: write-to-temp, then rename
- [ ] "Reveal in Finder" works from both the notification and the meeting's menu entry
- [ ] `Sharer` builds a `mailto:` draft via `NSSharingService` to all attendee emails
  - Subject: `Notes: <title> (<date>)`
  - Body: summary + action items
  - Transcript attachment optional (off by default)
- [ ] Onboarding wizard runs on first launch; covers all 3 required permissions with deep links to System Settings
- [ ] Consent notice displayed before first recording (user must acknowledge)
- [ ] `Scripts/check-licenses.sh` passes: all dependencies are MIT/Apache-2.0/BSD-class
- [ ] License check wired into `make check-licenses`; fails CI on unknown licenses
- [ ] State machine advances: `summarized → exported`
- [ ] End-to-end test with networking disabled after model download: calendar event → auto recording → `notes.md` + `transcript.txt` in output folder → draft email to attendees

## Key Files to Create

```
Services/
  FileExporter.swift        atomic file writer, folder management
  Sharer.swift              NSSharingService mailto: builder
App/
  OnboardingView.swift      3-step permission wizard
  SettingsView.swift        complete: output folder, all toggles
Scripts/
  check-licenses.sh         (already created in Phase 0 scaffold)
  licenses.json             allowlist: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause
Tests/
  FileExporterTests.swift
```

## Key APIs / Dependencies

- `Foundation.FileManager`, `URL.bookmarkData()` (security-scoped)
- `AppKit.NSSharingService`
- `NSWorkspace.shared.activateFileViewerSelecting` for Reveal in Finder
- `swift package show-dependencies --format json` for license extraction

## Risks

- `mailto:` body length limits in some mail clients (e.g. Mail.app truncates at ~4KB URL length); truncate body gracefully with "See attachment for full notes"
- Security-scoped bookmarks require entitlement `com.apple.security.files.user-selected.read-write` if sandboxed
