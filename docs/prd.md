# PRD & Execution Plan: “Scribe” — Local macOS Meeting Transcription Menu Bar App

**Status:** Draft v1.1 (Apple Notes export replaced with plain-text file output) · **Audience:** Claude Code (implementation agent) · **Date:** 2026-06-12

-----

## 1. Summary

Scribe is a macOS-native menu bar application (no Dock icon, no main window) that:

1. Watches the user’s Google Calendar for meetings.
1. Automatically records both the **microphone** and **system audio output** when a meeting starts.
1. Transcribes, diarizes, and summarizes the meeting **entirely on-device** using open-source models on Apple Silicon.
1. Attempts to map diarized speakers to attendee names from the calendar invite.
1. Writes the transcript, summary, and action items as **plain text/Markdown files** to a user-configurable folder (Apple Notes export deferred — see ADR-3).
1. Offers (with explicit user confirmation) to share the notes with other attendees via email.

**Hard constraints:** 100% local inference, fully open-source model weights and dependencies (permissive licenses), Apple Silicon only, macOS 14.4+.

-----

## 2. Key Architecture Decisions (read before coding)

These decisions correct or refine the original brief. Do not silently deviate from them; if one proves unworkable, surface it.

### ADR-1: Inference backend — hybrid CoreML (FluidAudio) + MLX (summarization), not MLX-only

**Context:** The brief asked for “Apple MLX as the backend” for transcription, diarization, and summarization. MLX is excellent for LLM inference in Swift, but it is **not** the best-supported open-source path for ASR + diarization in a native Swift app:

- `mlx-whisper` and pyannote diarization are **Python** libraries. Using them would force a bundled Python sidecar process (PyInstaller or embedded runtime), which is fragile to ship, heavy in memory, and pyannote’s pretrained weights are gated behind a Hugging Face access agreement — a poor fit for “completely open source” and unattended downloads.
- **FluidAudio** (Apache 2.0, pure Swift, Swift Package Manager) provides ASR (NVIDIA Parakeet TDT models, ~25 languages), speaker diarization (pyannote-derived community models converted to CoreML), speaker embeddings, and Silero VAD — all running on the Apple Neural Engine with low power draw, which matters for an always-on menu bar app. Models are hosted openly on Hugging Face under permissive licenses with auto-download support.

**Decision:**

- **ASR + VAD + diarization + speaker embeddings:** FluidAudio (CoreML/ANE).
- **Summarization + action-item extraction + speaker-name inference:** MLX via `mlx-swift` + `mlx-swift-lm` (`MLXLLM` / `MLXLMCommon` products), running a small open-weight instruct model, default **Qwen3-4B-Instruct 4-bit** (Apache 2.0), with **Llama-3.2-3B-Instruct 4-bit** as an alternative the user can select.
- All model downloads happen once, from Hugging Face, with checksums; everything after that is offline.

**Consequence:** The MLX requirement is satisfied where MLX is genuinely the right tool (LLM workloads); audio models run on ANE where they are faster and cheaper. If the user insists on MLX-only end to end, the fallback is a Python sidecar (`mlx-whisper` + a non-gated diarizer) — documented as out of scope for v1.

### ADR-2: System audio capture — Core Audio process taps

There is no trivial “record system speaker” API. Options:

|Option                                                                                             |macOS|Permission                                                     |Notes                                                            |
|---------------------------------------------------------------------------------------------------|-----|---------------------------------------------------------------|-----------------------------------------------------------------|
|**Core Audio process taps** (`CATapDescription`, `AudioHardwareCreateProcessTap`, aggregate device)|14.4+|TCC “System Audio Recording” (`NSAudioCaptureUsageDescription`)|Audio-only permission; no screen recording prompt. **Chosen.**   |
|ScreenCaptureKit audio                                                                             |13+  |Screen Recording permission                                    |Scary permission for an audio app. Fallback only.                |
|Virtual audio driver (BlackHole)                                                                   |any  |Driver install                                                 |Requires user to install kext/driver and reroute audio. Rejected.|

**Decision:** Use a Core Audio process tap on the default output device (global tap, excluding Scribe’s own process), mixed-down to mono 16 kHz alongside the microphone via `AVAudioEngine`. Mic and system audio are captured as **two separate channels/files** — this materially improves diarization (the mic channel is almost always the local user; remote participants are on the system channel).

**Prior art:** Granola and Notion AI Meeting Notes both capture device audio the same way conceptually (native desktop app taps mic + system output; no bot, no virtual driver). Because they support macOS 13, they use the ScreenCaptureKit path and their permission appears under “Screen & System Audio Recording” — Granola’s own docs note the screen-recording category is required only because macOS bundles system audio under it on older releases. Both also depend on the system **default output device** matching the meeting app’s output (their #1 documented support issue — replicate their guidance in our troubleshooting docs). Targeting 14.4+ lets Scribe use process taps and the cleaner audio-only permission instead. Unlike both products, all inference here stays on-device (they transcribe server-side).

### ADR-3: Output — plain text files (Apple Notes deferred)

**Decision (v1.1):** Output is written as plain files to a user-configurable folder (default `~/Documents/Meeting Notes/<YYYY-MM-DD> <title>/`): `notes.txt` (summary + decisions + actions + attendees), `transcript.txt` (speaker-labelled, timestamped), plus machine-readable `transcript.json` and `actions.json`. Files are the canonical store — simple, greppable, syncable, and zero automation permissions.

**Why Apple Notes was dropped from v1:** Notes has no public API; the only write path is AppleScript/Apple Events, which requires the `com.apple.security.automation.apple-events` entitlement, a “control Notes” consent prompt, blocks Mac App Store sandboxing, and is brittle across macOS releases. It remains a clean Phase-7 add-on because the exporter would only project the already-canonical local files into a note.

### ADR-4: Calendar source — EventKit first, Google Calendar API optional

If the user’s Google account is added to macOS (System Settings → Internet Accounts), **EventKit** exposes the Google calendar locally: event titles, times, attendees (`EKParticipant` with name + email via `mailto:` URL), and notes/location fields containing meeting URLs. This avoids implementing OAuth, token storage, and Google API quotas, and keeps the app more “local.”

**Decision:** v1 uses EventKit (requires Full Calendar Access permission, `NSCalendarsFullAccessUsageDescription`). A direct Google Calendar API (OAuth, `calendar.readonly`) connector is a stretch goal (Phase 7) for users who refuse to add the account to macOS — it provides richer conferencing metadata (`conferenceData` with Meet links) but adds OAuth complexity.

**Meeting detection heuristic:** an event counts as a “meeting” if it has ≥1 attendee other than the user, OR its title/location/notes contain a conferencing URL (Zoom, Meet, Teams, Webex regexes), and the user hasn’t declined it.

### ADR-5: Speaker-name assignment is heuristic — design for correction, not certainty

Diarization yields anonymous speakers (`SPEAKER_1…N`). Mapping them to invitee names from “audio cues” is genuinely hard and will sometimes be wrong. The pipeline must be confidence-scored and user-correctable, never presented as ground truth:

1. **Channel prior:** speech dominant on the mic channel → the local user (from EventKit’s `currentUser`/organizer match).
1. **Self-introduction & address cues:** the summarization LLM scans the transcript for cues (“Hi, it’s Priya”, “Thanks, John, over to you”) and proposes name↔speaker mappings with confidence scores, constrained to the invitee list.
1. **Count matching:** if detected speaker count == attendee count, propose a best-guess assignment; otherwise leave unmatched speakers as `Speaker N`.
1. **Voice enrollment (persistent):** store speaker embeddings (FluidAudio embedding extractor) per confirmed person locally; in later meetings, cosine-match embeddings against the enrolled library — this becomes the strongest signal over time.
1. **UI:** the post-meeting review popover lets the user reassign names in two clicks; corrections update the enrollment library.

### ADR-6: Sharing — email draft, never silent sending

Apple Notes collaboration (iCloud share links) cannot be automated via AppleScript. **Decision:** “Share with attendees” composes a pre-filled email (summary + action items + optional full transcript attachment as Markdown/PDF) addressed to attendee emails from the invite, opened in the default mail client via `NSSharingService`/`mailto:` — the **user always reviews and presses send**. Nothing is ever sent automatically (privacy + consent-law exposure; in many jurisdictions recording calls requires participant consent — see §6).

-----

## 3. Goals & Non-Goals

### Goals

- Zero-click capture: meetings transcribe themselves; the user only reviews output.
- Total privacy: audio and transcripts never leave the machine; no telemetry; no accounts (beyond what macOS/Google already sync).
- Fully open source: app code (MIT), and every model/dependency under MIT/Apache-2.0/BSD-class licenses.
- Native feel: SwiftUI `MenuBarExtra`, low idle footprint (<150 MB RAM idle, near-0% CPU idle).

### Non-Goals (v1)

- Windows/Linux/iOS. Intel Macs. macOS < 14.4.
- Real-time live captions UI (transcription may run streaming internally, but the product surface is post-meeting notes).
- Joining meetings as a bot, or per-participant audio via conferencing APIs.
- Translation; calendar write-back; CRM integrations; Mac App Store distribution.

-----

## 4. Personas & Core User Journey

**Persona:** an IC/manager on Apple Silicon who lives in Google Calendar + Zoom/Meet and wants automatic, private meeting notes without sending audio to a SaaS.

**Journey:**

1. First launch → onboarding popover walks through 3 permission grants (Calendar, Microphone, System Audio Recording) + Notes automation prompt on first export + model download (~2–3 GB, progress shown).
1. 9:58 — menu bar icon shows “Standup in 2 min”. 10:00 — icon turns red (recording), notification: “Recording Standup — click to stop.” (Auto-start is configurable: auto / ask / manual.)
1. 10:30 — meeting ends (calendar end + 2 min grace, or 90 s of sustained silence, or manual stop). Icon shows “Processing…”.
1. ~1–3 min later — notification: “Notes ready: Standup” (clicking reveals the folder in Finder). `notes.txt` and `transcript.txt` land in the output folder. Menu shows a review item to fix speaker names and a “Share with attendees…” button that opens a draft email.

-----

## 5. Functional Requirements

Priority: **P0** = must ship in v1, **P1** = should, **P2** = stretch.

### 5.1 Menu bar app shell

- **FR-1 (P0):** SwiftUI `MenuBarExtra` (window style) app; `LSUIElement = true` (no Dock icon). Icon states: idle, upcoming (≤5 min), recording (red dot), processing (spinner), error (badge).
- **FR-2 (P0):** Menu contents: next meeting (title + countdown), current recording controls (stop / pause / discard), last 5 meetings with status, Settings, Quit.
- **FR-3 (P0):** Launch-at-login toggle (`SMAppService`).
- **FR-4 (P0):** Native `UserNotifications` for: recording started, recording stopped, notes ready, errors, “meeting detected — start recording?” (in ask mode).

### 5.2 Calendar integration

- **FR-5 (P0):** Request Full Calendar Access via EventKit; poll/refresh upcoming events for the next 24 h every 5 min and on `EKEventStoreChanged`.
- **FR-6 (P0):** Classify events as meetings per ADR-4 heuristic; user can choose which calendars are watched in Settings.
- **FR-7 (P0):** Extract per meeting: title, start/end, organizer, attendee list (name + email + RSVP status), conferencing URL, event ID (for dedupe across recurring instances).
- **FR-8 (P1):** Per-event opt-out: “Don’t record this meeting / this series” from the upcoming-meeting menu item.

### 5.3 Audio capture

- **FR-9 (P0):** On meeting start (configurable lead: 0–2 min early), capture microphone via `AVAudioEngine` (mono, 16 kHz, Float32) — requires `NSMicrophoneUsageDescription`.
- **FR-10 (P0):** Simultaneously capture system output via Core Audio process tap + aggregate device (ADR-2), same format, **kept as a separate channel**.
- **FR-11 (P0):** Write both channels to disk continuously (CAF/WAV in `~/Library/Application Support/Scribe/recordings/<eventID>/`) so a crash loses ≤5 s of audio.
- **FR-12 (P0):** Stop conditions: calendar end + grace period (default 2 min, extends while voice activity continues, hard cap +30 min), 90 s sustained silence after the scheduled end, or manual stop. Manual “Record now” (ad-hoc meeting, no calendar event) must also work.
- **FR-13 (P0):** Honor macOS input device changes mid-recording (AirPods connect/disconnect) without dropping the session.
- **FR-14 (P1):** Pause/resume. **FR-15 (P1):** Configurable auto-delete of raw audio after successful transcription (default: keep 7 days).

### 5.4 Transcription (FluidAudio / Parakeet)

- **FR-16 (P0):** Transcribe both channels with Parakeet TDT (default `tdt-0.6b-v3`), producing word/segment timestamps. Streaming transcription during the meeting is preferred (spreads compute; enables future live view) but batch post-meeting is an acceptable v1 fallback — decide by Phase 2 spike.
- **FR-17 (P0):** Target real-time factor ≥ 5× on M1 (a 60-min meeting transcribes in ≤ 12 min post-hoc; effectively instant if streaming).
- **FR-18 (P1):** Language auto-detect within Parakeet’s supported set; surface unsupported-language failures gracefully.

### 5.5 Diarization & speaker naming

- **FR-19 (P0):** Run FluidAudio diarization on the **system-audio channel**; treat the mic channel’s dominant speaker as the local user. Merge into a single speaker-labelled timeline (resolve overlaps by channel energy).
- **FR-20 (P0):** Implement the ADR-5 naming pipeline; every assignment carries a confidence (high/medium/low) and provenance (channel / cue / enrollment / count-match).
- **FR-21 (P0):** Review UI (popover from the menu): list speakers with a 5 s audio snippet play button, dropdown of attendee names + free text; “Apply” rewrites the note.
- **FR-22 (P1):** Persistent local voice enrollment library (embeddings + name), with a Settings page to view/delete profiles (privacy requirement: deletable biometric-ish data, off by default until the user enables “Remember voices”).

### 5.6 Summarization & actions (MLX)

- **FR-23 (P0):** With the diarized transcript, generate via the local MLX model: (a) 5–10 sentence summary, (b) key decisions, (c) **action items** as structured JSON `{owner?, task, due?, sourceQuote}` — owners constrained to attendee names or “Unassigned”, (d) proposed meeting title if calendar title is generic (“Catch up”).
- **FR-24 (P0):** Chunked map-reduce summarization for long meetings (model context is finite); deterministic prompts checked into the repo under `Prompts/`.
- **FR-25 (P0):** JSON output validated against a schema; on parse failure retry once with a repair prompt, then degrade to summary-only and flag the note.
- **FR-26 (P1):** Optionally mirror action items to Apple Reminders (“Meeting Actions” list) via EventKit Reminders — off by default.

### 5.7 Output files

- **FR-27 (P0):** On pipeline completion, write to `<output folder>/<YYYY-MM-DD> <title>/`: `notes.txt` (Attendees, Summary, Decisions, Action Items), `transcript.txt` (speaker-labelled, timestamped segments), `transcript.json`, `actions.json`. Filenames sanitized; collisions suffixed.
- **FR-28 (P0):** Output folder is user-configurable (default `~/Documents/Meeting Notes/`), with security-scoped bookmark if sandboxed. “Reveal in Finder” from the notification and from each meeting’s menu entry.
- **FR-29 (P0):** Speaker-name corrections (FR-21) rewrite the files in place, atomically (write-temp-then-rename).

### 5.8 Sharing

- **FR-30 (P0):** “Share with attendees…” builds an email draft (default mail client) to attendee emails, subject `Notes: <title> (<date>)`, body = summary + actions, attaching `transcript.txt` (and optional PDF, P1). User reviews & sends manually (ADR-6).
- **FR-31 (P1):** Per-meeting toggle to exclude the full transcript from the share.

### 5.9 Settings & storage

- **FR-32 (P0):** Settings window (standard `Settings` scene): recording mode (auto/ask/manual), watched calendars, lead/grace times, audio retention, model selection + re-download, voice memory on/off, launch at login, output folder location.
- **FR-33 (P0):** All data under `~/Library/Application Support/Scribe/`; SQLite (GRDB) index of meetings/state; per-meeting folder for artifacts. A “Reveal data folder” and “Delete all data” button in Settings.
- **FR-34 (P0):** Structured logging via `os.Logger`; a “Copy diagnostics” action that never includes transcript content.

-----

## 6. Non-Functional Requirements

- **Privacy/network:** outbound network is permitted **only** to Hugging Face for model downloads (and Google, only if the optional Phase-7 API connector is enabled). Enforce by code review + an integration test that runs a full pipeline with networking blocked. No telemetry, no crash reporting by default.
- **Consent:** recording calls without consent is illegal in many jurisdictions (two-party consent states, etc.). On first run show a clear notice that the user is responsible for obtaining consent; provide the “ask before recording” mode as default. This is a product requirement, not legal advice.
- **Licensing:** app under MIT. Dependency budget: FluidAudio (Apache-2.0), mlx-swift / mlx-swift-lm (MIT), Qwen3 weights (Apache-2.0), Parakeet CoreML conversions (permissive per FluidAudio), GRDB (MIT). CI check (`licenses.json`) fails the build if a dependency lacks an allow-listed license. **Do not** use gated pyannote checkpoints directly.
- **Performance:** idle <150 MB RAM / ~0% CPU; recording <300 MB; processing peak <6 GB (4-bit 4B LLM + ASR) and must complete a 60-min meeting in <10 min on M1/16 GB; thermals: prefer ANE, throttle LLM batch size on low-power mode.
- **Reliability:** crash-safe audio (FR-11); the pipeline is a resumable state machine (RECORDED → TRANSCRIBED → DIARIZED → SUMMARIZED → EXPORTED) persisted in SQLite — relaunching the app resumes incomplete stages.
- **Concurrency:** Swift structured concurrency; one processing job at a time (queue back-to-back meetings); recording of meeting N+1 may start while N is processing.

-----

## 7. System Architecture

```
┌──────────────────────────────── Scribe.app (Swift 5.10+, SwiftUI) ───────────────────────────────┐
│                                                                                                  │
│  MenuBarExtra UI ── SettingsScene ── ReviewPopover ── Notifications                              │
│        │                                                                                         │
│  AppCoordinator (state machine, SQLite via GRDB)                                                 │
│   │        │            │              │                │               │              │         │
│   ▼        ▼            ▼              ▼                ▼               ▼              ▼         │
│ Calendar  Capture     ASR Engine    Diarizer        Summarizer      FileExporter   Sharer      │
│ Service   Service     (FluidAudio   (FluidAudio     (MLXLLM,        (txt/json to    (mailto/    │
│ (EventKit)(AVAudio-    Parakeet)     diar+embed)     Qwen3-4B q4)    output folder)  NSSharing) │
│           Engine +                                                                              │
│           CA process                                                                            │
│           tap)                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
Data flow: CalendarService → (meeting window) → CaptureService → mic.caf + system.caf
 → ASREngine → segments.json → Diarizer → speakers.json → SpeakerNamer (cues+embeddings+LLM)
 → Summarizer → notes.txt + actions.json → FileExporter → output folder → Sharer (on demand)
```

**Data model (SQLite):** `meetings(id, eventID, title, start, end, state, exportPath, error)`, `attendees(meetingID, name, email, role, rsvp)`, `speakers(meetingID, label, assignedAttendee, confidence, provenance)`, `actions(meetingID, owner, task, due, done)`, `voiceProfiles(personEmail, name, embeddingBlob, sampleCount)`.

**Permissions matrix (onboarding must verify all):** Microphone · System Audio Recording (tap) · Calendars (full access) · Notifications · optional Reminders.

-----

## 8. Execution Plan (for Claude Code)

Work in vertical phases; every phase ends with a runnable app and passing tests. Use Xcode 16+, Swift Package Manager only, repo layout:

```
Scribe/
  Scribe.xcodeproj            App/ (entry, MenuBarExtra, Settings, Review UI)
  Core/ (Coordinator, StateMachine, DB)   Services/ (Calendar, Capture, ASR, Diarize, Name, Summarize, Notes, Share)
  Prompts/                    Tests/ (unit + fixtures: 3 sample multi-speaker WAVs + expected JSON)
  Scripts/ (license-check, notarize)      docs/ (this PRD, ADRs)
```

### Phase 0 — Skeleton & plumbing (foundation)

- MenuBarExtra app, LSUIElement, icon states, Settings scene stub, launch-at-login, GRDB schema + migrations, state machine with persisted stages, os.Logger setup.
- **Accept:** app runs from menu bar; fake meeting rows advance through states on a timer; unit tests for state machine.

### Phase 1 — Calendar

- EventKit permission flow; meeting classifier (unit-test the heuristic against fixture events incl. Zoom/Meet/Teams URLs and recurring events); upcoming-meeting menu UI; opt-out per event.
- **Accept:** with a Google account in macOS Calendar, the menu shows the real next meeting with attendees.

### Phase 2 — Capture (riskiest native code — do early, spike first)

- Mic capture via AVAudioEngine; **spike:** Core Audio process tap (CATapDescription on default output, aggregate device, read proc) — validate Zoom/Meet/Teams audio is captured on 14.4+ and 15.x; crash-safe dual-channel writer; stop conditions incl. VAD-based silence (FluidAudio Silero VAD); manual record; device-change handling.
- **Accept:** join a test Meet call; both sides of audio land in two CAF files; killing the app mid-call loses <5 s.

### Phase 3 — Transcription

- Integrate FluidAudio Parakeet (auto model download with progress UI + checksum); batch transcription of both channels with timestamps; decide streaming vs batch from the spike; RTF benchmark target in CI-style test on fixture audio.
- **Accept:** fixture 10-min WAV → timestamped transcript, WER sanity-checked against fixture reference.

### Phase 4 — Diarization + speaker naming

- FluidAudio diarizer on system channel; mic-channel = local user prior; timeline merge; cue-based naming via LLM prompt (constrained to invitee list, JSON with confidence); count-matching fallback; Review popover with snippet playback + reassignment; (P1) embedding enrollment store behind a setting.
- **Accept:** on a 3-speaker fixture with scripted self-introductions, ≥2 of 3 speakers auto-named correctly; manual reassignment rewrites outputs.

### Phase 5 — Summarization & actions (MLX)

- Integrate mlx-swift-lm; model download/selection; chunked map-reduce prompts (in `Prompts/`); JSON-schema-validated actions with retry/repair; degrade-gracefully path; optional Reminders mirror (P1).
- **Accept:** fixture transcript → summary, decisions, ≥90% of planted action items extracted with correct owners; memory peak <6 GB.

### Phase 6 — File export, sharing, onboarding, polish

- File exporter (atomic writes, sanitized names, configurable folder, reveal-in-Finder); share-via-email draft with attachments; onboarding wizard checking every permission with deep links to System Settings; consent notice; settings completeness; notarization script; license-check script wired into build.
- **Accept:** end-to-end: calendar event → auto recording → notes.txt + transcript.txt in the output folder → draft email to attendees, with networking disabled after model download.

### Phase 7 (stretch) — Apple Notes export (AppleScript, projects the canonical files into a note), Google Calendar API connector, PDF export, live caption window, menu-bar mini transcript.

### Testing & risk notes for the agent

- Unit-test everything non-UI; integration tests run the full pipeline on fixture WAVs (no live audio in CI). UI is thin; keep logic in services.
- **Top risks:** (1) process-tap API edge cases per macOS version — keep ScreenCaptureKit fallback behind a flag (this is the path Granola/Notion ship today, so it’s battle-tested); (2) default-output-device mismatch with the meeting app silently capturing nothing — detect zero-energy system channel during a meeting and warn; (3) diarization quality on far-field/echoey audio — dual-channel design is the main mitigation; (4) LLM JSON discipline — schema + repair prompt + degrade path.
- When blocked by a private-API temptation, stop and flag — everything in this PRD is achievable with public APIs.

## 9. Open Questions (answer before Phase 4)

1. Should “Remember voices” (embedding enrollment) be in v1 at all, given it stores voice-derived data? (Default: ship behind off-by-default toggle.)
1. Auto-record default: `ask` (recommended, consent-safer) or `auto`?
1. Transcript in the shared email: include by default or summary-only?
1. Minimum supported macOS: hold at 14.4 (process taps) or 15.0 (simpler tap APIs)?