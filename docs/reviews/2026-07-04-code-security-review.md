# Code, Security & Testing Review — 2026-07-04

> **Status update:** all High findings (H1–H3), M1–M3, M5, and L1–L6 were fixed in **v0.2.0**
> (see `CHANGELOG.md`). M4 (Developer ID signing/notarization) remains open — it requires
> signing credentials. The CI lint gap is addressed with a non-blocking SwiftLint job pending
> cleanup of pre-existing strict-mode violations.

Scope: full repository at `main` (v0.1.9, commit `8c45470`). Focus: correctness/functionality
bugs, security posture, best practices, and test coverage.

Overall the codebase is in good shape: clean actor-based concurrency, thin UI, pure/testable
core logic, atomic file writes, a real CI pipeline (build+test, gitleaks, license allowlist,
weekly CodeQL), pre-commit hygiene hooks, and privacy-conscious defaults (consent gate,
ask-before-record, enrollment off by default). The findings below are ordered by severity.

---

## High

### H1. Recurring meetings break the processing pipeline and overwrite prior notes

`eventID` is `calendarItemExternalIdentifier` (`CalendarService.swift:152`), which is **shared by
every occurrence of a recurring series**. Everything downstream keys on it:

- **Second occurrence is never processed.** After the first occurrence completes, the meeting row
  is in the terminal `exported` state. When the next occurrence's recording stops,
  `handleRecordingStopped` (`AppCoordinator.swift:558-564`) attempts
  `transition(to: .recorded)`, which `StateMachine` rejects (`exported → recorded` is invalid).
  The catch only logs; `processMeeting` is never called. Result: for any weekly/daily meeting,
  every occurrence after the first records audio but silently produces **no transcript and no
  notes**.
- **Audio from the prior occurrence is destroyed first.** The recording directory is
  `recordings/<eventID>/` (`CaptureService.swift:82-84`), so `mic.caf`/`system.caf` from the
  previous occurrence are truncated by `AVAudioFile(forWriting:)` before the failed transition is
  even reached.
- **Re-export overwrites last week's notes.** `performExport` reuses `meeting.exportPath`
  (`AppCoordinator.swift:834`), so if state ever allowed processing, the new occurrence would
  overwrite the previous occurrence's export folder.
- **Ask-mode prompts fire once per series per app run.** `promptedEventIDs`
  (`AppCoordinator.swift:208`, `:432`) is keyed by `externalID`; a menu-bar app running for days
  will not prompt for the second daily standup.
- **Opt-out is per-series**, though the UI copy says "this meeting" (`OptOutStore`). Possibly
  intended — worth an explicit product decision.

**Recommendation:** key meetings, recording directories, and prompts on
*(externalID, occurrence start)* — e.g. `"\(externalID)-\(Int(start.timeIntervalSince1970))"` —
or use `EKEvent.eventIdentifier` plus the occurrence date. Add a regression test: two occurrences
of one series must yield two meeting rows, two recording dirs, and two export dirs.

### H2. Path traversal via calendar-controlled `eventID` (security)

The recordings directory is built with `appendingPathComponent(eventID)` in at least:
`CaptureService.swift:83`, `ASREngine.swift:57`, `AppCoordinator.swift:626, 696, 829, 1217, 1247`.

`calendarItemExternalIdentifier` derives from the iCalendar `UID`, which is **controlled by the
inviter** of any meeting on the user's calendar. A malicious invite with a UID like
`../../../../Users/victim/some/path` causes Scribe to create directories and write
`mic.caf` / `system.caf` / `segments.json` / `notes.md` at an attacker-chosen path outside the
recordings root — and `discardRecording` (`CaptureService.swift:142-149`) does
`FileManager.removeItem(at:)` on that derived directory, i.e. **attacker-influenced recursive
delete**.

**Recommendation:** sanitize the ID once at the trust boundary (reject/replace `/`, `:`, `..`,
control chars — reuse `FileExporter.sanitize`), or better, hash it
(`SHA-256(eventID).hexPrefix(16)`) for the directory name. Add a unit test that a hostile
`eventID` stays inside `recordingsRoot`.

### H3. "Relaunch resumes incomplete stages" is documented but not implemented

CLAUDE.md and the state-machine design promise that incomplete meetings resume after relaunch.
Nothing in `AppCoordinator.start()` (or anywhere else) queries for meetings in
`recorded`/`transcribed`/`diarized`/`summarized` and restarts the pipeline. Consequences:

- A crash or quit mid-pipeline strands the meeting forever; the audio sits on disk, no notes.
- `processMeeting` early-returns when `isRecording` is true (`AppCoordinator.swift:590`), leaving
  the meeting in `recorded` with no retry path at all.

**Recommendation:** on launch (and after each recording finishes), scan the DB for non-terminal,
non-`scheduled` meetings and resume the appropriate stage. This also gives H1's stranded
recordings a recovery path.

---

## Medium

### M1. "Join & transcribe" opens attacker-supplied URLs with substring-only validation

`MeetingClassifier.conferenceURL` (`MeetingClassifier.swift:103-119`) accepts any URL whose
*string* matches a pattern like `zoom\.us/j/` **anywhere** — `https://evil.com/zoom.us/j/x`
qualifies. Event notes/location are inviter-controlled, and `joinAndTranscribe`
(`AppCoordinator.swift:466-472`) passes the result straight to `NSWorkspace.shared.open` with no
scheme check, so custom URL schemes (`file:`, app-registered schemes) could also slip through the
`NSDataDetector` path. One click on the meeting prompt triggers it.

**Recommendation:** parse with `URLComponents`, require `https`, and match the **host** against an
allowlist (`zoom.us`/`*.zoom.us`, `meet.google.com`, `teams.microsoft.com`, `*.webex.com`).
`hasConferencingURL` (classification only) can stay loose, but the *opened* URL must be strict.

### M2. Model supply chain: TOFU-only integrity, and dead checksum code in `download-models.sh`

- `ModelDownloader` (Services) records a SHA-256 manifest **after** first download
  (trust-on-first-use): it detects later on-disk corruption but not a compromised/spoofed first
  download. And on any load failure it wipes and re-downloads, then **rewrites the manifest from
  the new download** (`ModelDownloader.swift:47-54`), so the retry path re-TOFUs — an integrity
  failure can be silently laundered into a new trusted state.
- `Scripts/download-models.sh` defines a `download_file` helper with checksum verification that is
  **never called**; the script downloads nothing and tells the user checksums should be updated.
  Misleading dead code.
- MLX weights come from `mlx-community/gemma-4-E4B-it-qat-4bit` via the HF downloader with no
  pinned revision or digest.

**Recommendation:** pin known-good digests (or at least an HF revision/commit) for both model
sets; make a checksum-mismatch-after-retry a hard, user-visible error rather than re-TOFU;
either implement or delete the script's checksum path.

### M3. Raw recordings are retained forever with no cleanup or setting

`recordings/<eventID>/` keeps `mic.caf`, `system.caf`, `segments.json`, transcripts, and notes in
Application Support indefinitely. For a consent-sensitive meeting recorder this is a privacy
liability (and unbounded disk growth — hours of CAF audio per meeting). `AudioSnippet` also writes
preview `.caf` files to the temp directory and never removes them.

**Recommendation:** add a retention policy (e.g. delete/offer-to-delete raw audio after successful
export, or a "keep recordings for N days" setting), plus a "Delete meeting data" affordance.
Clean up snippet temp files after playback.

### M4. Distribution: ad-hoc signing, no notarization, no sandbox

`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_ENTITLEMENTS = ""` (project), and the DMG ships ad-hoc
signed and unnotarized. Users must right-click-open past Gatekeeper; TCC grants don't survive
updates without a stable identity (the Makefile's optional `CODESIGN_IDENTITY` only partially
covers this). App Sandbox is off — `OutputFolderStore` is already bookmark-based, so the main
prerequisite for sandboxing exists.

**Recommendation:** sign releases with a Developer ID certificate and notarize in the release
workflow. Evaluate enabling App Sandbox with `com.apple.security.files.user-selected.read-write`
(process-tap compatibility is the open question to test).

### M5. Pipeline failures are silent for the user

Every stage failure (`processMeeting`, `diarizeAndName`, `summarizeMeeting`, `exportMeeting`)
writes `meetings.error` and logs, but nothing surfaces to the user — the menu icon returns to
idle (`updateStatusForUpcoming` runs in `defer`) and no notification is posted. A user can sit
through a meeting and never learn their notes failed. Summarization has a graceful degrade path;
transcription/diarization/export failures do not.

**Recommendation:** post a notification on stage failure (mirroring `notifyExported`), and/or show
an error row in the menu with a retry action (which H3's resume logic would provide).

---

## Low

- **L1. `CaptureService.startRecording` silently no-ops when already recording**
  (`CaptureService.swift:89-92`), but `AppCoordinator.startCapture` then unconditionally sets
  `isRecording = true` / `status = .recording` (`AppCoordinator.swift:532-535`). If the guard ever
  trips (double-fire of auto-start), the coordinator's state desyncs. Return a `Bool`/throw
  instead.
- **L2. `EmbeddingCodec.decode` (`VoiceEnrollmentStore.swift:43-48`)** binds raw `Data` bytes to
  `Float` without alignment guarantees — technically UB for a misaligned blob. Use
  `withUnsafeBytes { Array($0.loadUnaligned...) }` or copy via `Data.copyBytes`.
- **L3. `Database.insert` returns `copy.id ?? 0`** (`Database.swift:68`) — a `0` sentinel meeting
  ID would corrupt downstream lookups; throw instead.
- **L4. `MeetingClassifier.parseMailto` keeps any `?query`** from the mailto URL in the "email",
  which then flows into DB rows and share drafts. Strip at `?`.
- **L5. Review-popover caches grow unbounded** (`meetingEmbeddings`/`meetingSnippets`,
  `AppCoordinator.swift:214-215`) for the app's lifetime — cap or evict after review.
- **L6. `status = .error` is sticky** — once set (e.g. mic denied), `updateStatusForUpcoming`
  guards `status != .error` forever (`AppCoordinator.swift:398`), so the icon stays on error even
  after the user fixes the permission, until some other path resets it.

---

## Best practices & CI

- **SwiftLint/swift-format are not enforced in CI.** `make lint` (`swiftlint --strict`) and
  `make format` exist, and `.swiftlint.yml` is checked in, but `ci.yml` runs neither — style
  gates that only run locally will drift. Add a lint job (SwiftLint runs fine on Ubuntu via the
  official docker image, or as a step in the macOS job).
- CodeQL weekly-only is a reasonable, well-documented tradeoff (Metal toolchain flake).
- gitleaks + allowlist config, license allowlist gate, audio/model-weight commit blockers, and the
  SPDX-header hook are all good. `actions/checkout@v6` / pinned major versions are fine; consider
  pinning by SHA for supply-chain rigor.
- No Dependabot/Renovate config — SPM dependencies (GRDB, FluidAudio, mlx-swift on `main` branch!)
  won't get update PRs. Note `mlx-swift-lm` tracks a **branch**, so builds are not reproducible;
  pin a revision.

## Test coverage

~100 tests with good coverage of the pure logic (state machine, classifier, chunker, summarizer
orchestration + degrade paths, exporter naming, sharer drafts, stop-condition monitor, countdown
formatting). Gaps, in priority order:

1. **`AppCoordinator` pipeline orchestration** — the largest file (1,271 lines) has zero tests;
   H1 and H3 live there. Extract the stage-advance logic into a testable, UI-free type.
2. **Recurring-event scenarios** (H1) — none exist anywhere.
3. **Path-safety regression tests** (H2) — hostile `eventID`/title must stay inside app dirs.
4. **`conferenceURL` adversarial cases** (M1) — lookalike hosts, non-https schemes.
5. **`ModelDownloader` TOFU logic** (M2) — manifest write/validate/retry paths are untested.
6. **`ArtifactWriter`** render/rewrite-after-reassignment, **`VoiceMath`/`EmbeddingCodec`**
   round-trip, **`OptOutStore`** — small pure units, cheap to cover.

---

*Reviewed files: all of `App/`, `Core/`, `Services/`, `Scripts/`, `Tests/`, CI workflows, and the
Xcode project settings. No hardcoded secrets, no network calls outside model downloads, and the
no-cloud/consent posture of the PRD is faithfully implemented in the code that exists.*
