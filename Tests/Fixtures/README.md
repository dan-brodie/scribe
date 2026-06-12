# Test Fixtures

Audio fixtures for the ASR integration test (`ASREngineTests`).

## Required files

| File | Purpose |
|------|---------|
| `sample-10min.wav` | ~10 min of clear meeting-style speech, any sample rate (resampled to 16 kHz mono internally) |
| `sample-10min-reference.txt` | Ground-truth transcript for WER scoring |

These are **not checked into the repo** (binary audio, licensing). Fetch them with:

```bash
make download-fixtures
```

When absent, `testFixtureTranscriptionMeetsWERAndRTF` is skipped (via `XCTSkip`)
so the unit suite stays green offline. The test also downloads the Parakeet v3
models (~hundreds of MB) on first run.

Use a public-domain / CC0 speech sample (e.g. LibriVox) so the fixture can be
redistributed; record the source URL in `Scripts/download-fixtures.sh`.
