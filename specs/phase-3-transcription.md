# Phase 3 — Transcription

status: not-started

## Goal

Integrate FluidAudio Parakeet for on-device ASR of both audio channels, with model auto-download, progress UI, and a streaming-vs-batch decision from the Phase 2 spike.

## Acceptance Criteria

- [ ] `ASREngine` wraps FluidAudio `AsrManager` (batch) or `StreamingEouAsrManager` (streaming)
- [ ] First run triggers model download with progress shown in menu bar / notification
- [ ] Model download uses `AsrModels.downloadAndLoad(version: .v3)` (multilingual)
- [ ] SHA-256 checksum validated after download; corrupt download retried once then errors
- [ ] Both mic and system channels transcribed separately, producing word/segment timestamps
- [ ] Transcripts merged into a single timeline (mic timestamps + system timestamps)
- [ ] Real-time factor ≥5× on M1 for batch transcription (60 min meeting → ≤12 min)
- [ ] Unsupported language detected and surfaced as a warning (not a crash)
- [ ] `segments.json` written to the meeting's recording folder
- [ ] State machine advances: `recorded → transcribed` on completion
- [ ] Integration test: `Tests/Fixtures/sample-10min.wav` → timestamped transcript, WER <20% vs. reference

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
