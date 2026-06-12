# Phase 2 — Audio Capture (Riskiest Phase — Spike First)

status: not-started

## Goal

Capture microphone and system audio as two separate crash-safe CAF files, with automatic start/stop tied to meeting times and manual override.

## Acceptance Criteria

- [ ] Mic captured via `AVAudioEngine` at 16 kHz mono Float32
- [ ] System audio captured via Core Audio process tap (macOS 14.4+), same format, separate file
- [ ] Both files written to `~/Library/Application Support/Scribe/recordings/<eventID>/mic.caf` and `system.caf`
- [ ] Audio flushed to disk every ≤5 s (crash loses <5 s of audio)
- [ ] Recording starts automatically at meeting start (configurable lead: 0–2 min)
- [ ] Recording stops on: calendar end + grace period (default 2 min), 90 s sustained silence post-schedule, or manual stop
- [ ] Manual "Record now" works without a calendar event
- [ ] AirPods connect/disconnect mid-recording is handled without dropping the session
- [ ] Zero-energy system channel (device mismatch) detected after 30 s → user warned via notification
- [ ] `CaptureService` exposes `startRecording(for:)` and `stopRecording()` async methods
- [ ] ScreenCaptureKit fallback path compiles behind `SCREENCAPTURE_FALLBACK` flag (not default)
- [ ] Unit tests: stop-condition logic (silence detection, grace period) with mock audio input

## Key Files to Create

```
Services/
  CaptureService.swift      Actor; owns AVAudioEngine, process tap lifecycle
  AudioWriter.swift         CAF file writer with periodic flush
  StopConditionMonitor.swift silence + grace period logic using FluidAudio VAD
App/
  MenuBarView.swift         recording controls: stop / pause / discard
Tests/
  CaptureServiceTests.swift  stop condition unit tests (mock audio)
```

## Key APIs / Dependencies

- `AVAudioEngine`, `AVAudioInputNode`
- Core Audio process taps — see `docs/vendor/core-audio-taps.md` for full pattern
- FluidAudio `VadManager` for silence detection (VAD)
- `NSMicrophoneUsageDescription` + `NSAudioCaptureUsageDescription` in Info.plist

## Risks

- **Process tap API edge cases across macOS 14.4 and 15.x** — test both; keep ScreenCaptureKit fallback
- **Default output device mismatch** — #1 documented support issue for Granola/Notion AI; implement zero-energy detection and clear warning
- Spike task: before full implementation, verify Zoom/Meet/Teams audio is captured on target macOS versions
