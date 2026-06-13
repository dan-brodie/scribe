# Phase 3 — Transcription

status: complete

## Goal

Integrate FluidAudio Parakeet for on-device ASR of both audio channels, with model auto-download, progress UI, and a streaming-vs-batch decision from the Phase 2 spike.

## Acceptance Criteria

- [x] `ASREngine` wraps FluidAudio `AsrManager` (batch) or `StreamingEouAsrManager` (streaming)
- [x] First run triggers model download with progress shown in menu bar / notification
- [x] Model download uses `AsrModels.downloadAndLoad(version: .v3)` (multilingual)
- [x] SHA-256 checksum validated after download; corrupt download retried once then errors
- [x] Both mic and system channels transcribed separately, producing word/segment timestamps
- [x] Transcripts merged into a single timeline (mic timestamps + system timestamps)
- [x] Real-time factor ≥5× on M1 for batch transcription (60 min meeting → ≤12 min)
- [x] Unsupported language detected and surfaced as a warning (not a crash)
- [x] `segments.json` written to the meeting's recording folder
- [x] State machine advances: `recorded → transcribed` on completion
- [x] Integration test: `Tests/Fixtures/sample-10min.wav` → timestamped transcript, WER <20% vs. reference

## Key Files to Create

```
Services/
  ASREngine.swift           Actor; batch or streaming transcription
  ModelDownloader.swift     progress-reporting HF download + checksum
App/
  MenuBarView.swift         "Transcribing…" state + progress
Tests/
  ASREngineTests.swift      fixture WAV → transcript, RTF check
Tests/Fixtures/
  sample-10min.wav          (add via make download-fixtures)
  sample-10min-reference.txt
```

## Key APIs / Dependencies

- FluidAudio `AsrModels`, `AsrManager`, `StreamingEouAsrManager` — see `docs/vendor/fluidaudio.md`
- `AudioConverter.resampleAudioFile(path:)` for WAV → Float32
- `URLSession` for model download with `downloadTask(with:completionHandler:)`

## Risks

- Streaming vs. batch: streaming spreads compute and enables future live captions but is more complex; batch is simpler and acceptable for v1 — make the call after the Phase 2 spike
- RTF on M1/8GB vs. M1/16GB may differ; benchmark on lowest-spec target hardware
