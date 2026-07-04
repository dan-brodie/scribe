# Scribe

macOS 14.4+ menu bar app: auto-records mic + system audio during Google Calendar meetings,
transcribes/diarizes/summarizes entirely on-device (Apple Silicon), writes plain-text notes
to a configurable local folder. No cloud, no accounts beyond what macOS already syncs.

---

## Stack

| Layer | Technology | SPM Product | Version |
|-------|-----------|-------------|---------|
| ASR + VAD + Diarization | FluidAudio (CoreML/ANE) | `FluidAudio` | ≥0.12.4 |
| Summarization + actions | mlx-swift-lm | `MLXLLM`, `MLXLMCommon` | branch: main |
| MLX runtime | mlx-swift | `MLX`, `MLXNN` | ≥0.10.0 |
| Database | GRDB.swift | `GRDB` | ≥7.11.0 |
| Calendar | EventKit | built-in | macOS 14.4+ |
| System audio | Core Audio process taps | built-in | macOS 14.4+ |
| UI | SwiftUI `MenuBarExtra` | built-in | macOS 14.4+ |

Default LLM: `google/gemma-4-E4B-it` 4-bit via `mlx-community/gemma-4-E4B-it-qat-4bit` (Apache-2.0, ungated). Lighter alt: Gemma 4 `E2B` 4-bit.

---

## ADR Quick-Ref

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Inference backend | FluidAudio (audio), MLX (LLM) | mlx-whisper/pyannote are Python; FluidAudio is pure Swift/ANE |
| 2 | System audio | Core Audio process tap (`CATapDescription`) | Audio-only TCC on 14.4+; avoids ScreenCaptureKit's screen-recording prompt |
| 3 | Output format | Markdown + JSON files | No public Notes API; files are greppable, syncable, zero extra permissions |
| 4 | Calendar source | EventKit (local Google sync) | No OAuth if Google account is in macOS Internet Accounts |
| 5 | Speaker naming | Heuristic pipeline (channel prior + LLM cues + enrollment) | Never ground truth — confidence-scored, always user-correctable |
| 6 | Sharing | `mailto:` draft via `NSSharingService` | User always presses Send; no silent transmission |

Full ADRs: `docs/adr/`

---

## State Machine

```
RECORDED → TRANSCRIBED → DIARIZED → SUMMARIZED → EXPORTED
```

Persisted in SQLite (`meetings.state`). App relaunch resumes incomplete stages.
One processing job at a time; recording of meeting N+1 may start while N processes.

---

## SQLite Schema

```
meetings      (id, eventID, title, start, end, state, exportPath, error)
attendees     (meetingID, name, email, role, rsvp)
speakers      (meetingID, label, assignedAttendee, confidence, provenance)
actions       (meetingID, owner, task, due, done)
voiceProfiles (personEmail, name, embeddingBlob, sampleCount)
```

---

## Repo Layout

```
Scribe.xcodeproj
App/           MenuBarExtra, SettingsScene, ReviewPopover, onboarding
Core/          AppCoordinator, StateMachine, DB (GRDB migrations)
Services/      CalendarService, CaptureService, ASREngine, Diarizer,
               SpeakerNamer, Summarizer, FileExporter, Sharer
Prompts/       LLM prompt templates (checked into repo, loaded at runtime)
Tests/         Unit + integration; fixture WAVs under Tests/Fixtures/
Scripts/       download-models.sh, check-licenses.sh
docs/          prd.md, adr/, vendor/
specs/         Phase backlog (phase-0 … phase-7)
```

---

## Coding Rules

- Swift structured concurrency everywhere (`async/await`, `Actor`); no `DispatchQueue` except Core Audio C callbacks
- Thin UI: all logic lives in `Services/` or `Core/`; views only bind to `@Observable` state
- No gated model weights: only MIT/Apache-2.0/BSD-class licenses (CI enforced via `make check-licenses`)
- LLM prompts in `Prompts/*.md` — no multi-line string literals inline in Swift
- Test everything non-UI; integration tests use fixture WAVs, never live audio
- Crash-safe audio: write to disk continuously, flush every ≤5 s

---

## Key Commands

```bash
make build           # xcodebuild Scribe scheme
make test            # run ScribeTests
make lint            # swiftlint --strict
make format-fix      # swift-format in-place
make download-models # explains in-app model downloads (models download inside Scribe)
make check-licenses  # fail on non-allowlisted dependency licenses
make clean           # remove .build/ and DerivedData/
```

---

## Spec Backlog

| Phase | File | Goal |
|-------|------|------|
| 0 | `specs/phase-0-skeleton.md` | App shell, GRDB schema, state machine, logging |
| 1 | `specs/phase-1-calendar.md` | EventKit integration, meeting classifier, per-event opt-out |
| 2 | `specs/phase-2-capture.md` | Mic + process tap dual-channel capture, crash-safe writer |
| 3 | `specs/phase-3-transcription.md` | FluidAudio Parakeet, model download with progress, RTF ≥5× |
| 4 | `specs/phase-4-diarization.md` | Diarizer, speaker naming, Review popover, voice enrollment |
| 5 | `specs/phase-5-summarization.md` | MLX LLM, chunked map-reduce, JSON validation + repair |
| 6 | `specs/phase-6-export-sharing.md` | File exporter, email share draft, onboarding wizard, license CI |
| 7 | `specs/phase-7-stretch.md` | Apple Notes export, Google Calendar API, PDF, live captions |

---

## Vendor Docs (local — no web fetch needed)

| Library | Ref |
|---------|-----|
| FluidAudio | `docs/vendor/fluidaudio.md` |
| mlx-swift-lm / MLXLLM | `docs/vendor/mlx-swift-lm.md` |
| GRDB.swift | `docs/vendor/grdb.md` |
| Core Audio process taps | `docs/vendor/core-audio-taps.md` |
| EventKit | `docs/vendor/eventkit.md` |

---

## Permissions Matrix

| Permission | Info.plist key | When granted |
|-----------|---------------|--------------|
| Microphone | `NSMicrophoneUsageDescription` | Phase 2 onboarding |
| System Audio Recording | `NSAudioCaptureUsageDescription` | Phase 2 onboarding |
| Calendars (full) | `NSCalendarsFullAccessUsageDescription` | Phase 1 onboarding |
| Notifications | `NSUserNotificationUsageDescription` | Phase 0 |
| Reminders (optional) | `NSRemindersFullAccessUsageDescription` | Phase 5, off by default |

---

## Open Questions (resolve before Phase 4)

1. Ship voice enrollment (`voiceProfiles`) in v1? → Recommended: yes, behind off-by-default "Remember voices" toggle
2. Auto-record default: `ask` or `auto`? → Recommended: `ask` (consent-safer)
3. Include full transcript in shared email by default? → Recommended: off (summary + actions only)
4. Hold macOS min at 14.4 (process taps) or advance to 15.0 (simpler tap APIs)? → Hold at 14.4
