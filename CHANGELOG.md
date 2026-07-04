# Changelog

## v0.2.0 — 2026-07-04

Security & reliability release addressing the findings of the 2026-07-04 code
review (`docs/reviews/2026-07-04-code-security-review.md`).

### Fixed — high severity

- **Recurring meetings produce notes for every occurrence** (H1). Meetings,
  recordings, prompts, and exports are now keyed per occurrence
  (`externalID` + start time) instead of per series. Previously the second
  and later occurrences of any recurring meeting silently produced no notes,
  overwrote the prior occurrence's audio, and re-used its export folder.
- **Path traversal via calendar invites** (H2). Recording directories are now
  derived through `RecordingPaths`, which sanitizes the inviter-controlled
  event identifier and appends a SHA-256 digest. A malicious iCalendar `UID`
  can no longer write or delete files outside Scribe's recordings root.
  Directories from earlier versions are still found via a guarded legacy
  fallback.
- **Interrupted meetings resume at launch** (H3). Meetings left mid-pipeline
  by a crash or quit are now picked up at the next launch and completed from
  the stage where they stopped.

### Fixed — medium severity

- **"Join and transcribe" only opens trusted links** (M1). The conference URL
  must be `https` on a trusted conferencing host (Zoom, Google Meet, Teams,
  Webex, incl. subdomains) — substring lookalikes such as
  `https://evil.com/zoom.us/j/…` no longer qualify.
- **Model integrity failures are surfaced, not re-trusted** (M2). A checksum
  mismatch now re-downloads once and re-validates against the existing
  manifest; a second mismatch is a hard error. `Scripts/download-models.sh`
  no longer carries misleading dead checksum code.
- **Audio retention is now controllable** (M3). New Settings → Privacy toggle
  "Delete audio after notes are exported" (off by default). Speaker-snippet
  temp files are cleaned up after playback.
- **Pipeline failures are visible** (M5). A failed stage now posts a
  notification and shows the error icon instead of failing silently; the
  recording is kept and retried at next launch.

### Fixed — low severity

- Duplicate capture starts are rejected explicitly instead of silently
  desyncing the menu-bar state (L1).
- Voice-embedding decoding no longer relies on aligned memory (L2).
- Database inserts fail loudly instead of returning a sentinel row ID (L3).
- `mailto:` attendee addresses strip header queries (`?subject=…`) (L4).
- Speaker-review caches are bounded to the last 8 meetings (L5).
- The error icon clears once a denied microphone permission is granted (L6).

### Infrastructure

- SwiftLint job added to CI (non-blocking until pre-existing violations are
  cleaned up) and Dependabot enabled for SPM + GitHub Actions.
- `mlx-swift-lm` is pinned to a revision instead of tracking `main`, making
  builds reproducible.
- Version bumped to 0.2.0.

### Known items not addressed in this release

- Developer ID signing / notarization (M4) requires signing credentials and
  remains open; releases are still ad-hoc signed.
- `AppCoordinator` orchestration remains untested; extracting it into a
  testable pipeline type is follow-up work.

## v0.1.9 and earlier

See GitHub releases and merged PRs.
