# ADR-002: System Audio Capture — Core Audio Process Taps

## Status
Accepted

## Context
There is no trivial "record system speaker" API. Three options were considered:

| Option | macOS | Permission | Notes |
|--------|-------|-----------|-------|
| Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) | 14.4+ | `NSAudioCaptureUsageDescription` | Audio-only TCC; no screen recording prompt |
| ScreenCaptureKit audio | 13+ | Screen Recording | Scary permission for an audio app |
| Virtual audio driver (BlackHole) | any | Driver install | Requires user to install kext and reroute audio |

## Decision
Use a Core Audio process tap on the default output device (global tap, excluding Scribe's own process), mixed-down to mono 16 kHz alongside the microphone via `AVAudioEngine`.

Mic and system audio are captured as **two separate channels/files** — this materially improves diarization (mic ≈ local user; system ≈ remote participants).

Minimum macOS: **14.4** (process tap API introduced here).

Keep ScreenCaptureKit path behind `#if SCREENCAPTURE_FALLBACK` compile flag.

## Consequences
- Cleaner permission prompt: "Scribe wants to record audio from other apps" vs. screen recording
- Dual-channel design is the primary mitigation for diarization quality on mixed audio
- Top risk: default output device mismatch (meeting app uses a different device) — detect zero-energy system channel and warn user
