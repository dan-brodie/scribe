# Phase 5 — Summarization & Action Extraction (MLX)

status: complete

## Goal

Generate meeting summary, decisions, and structured action items from the diarized transcript using a local MLX LLM, with chunked map-reduce for long meetings.

## Acceptance Criteria

- [x] `Summarizer` runs behind an `LLMClient` seam. **Default backend: Apple Foundation Models** (on-device, OS-native, no download — `FoundationModelsLLMClient`, macOS 26+). The MLX/Gemma path (`MLXLLMClient`, `#huggingFaceLoadModelContainer`, Gemma 4 E4B-it 4-bit) is retained behind a feature flag (`SummarizationBackend` / Settings → Summarization) and is the automatic fallback on pre-26 / non-Apple-Intelligence hardware
- [x] First run: Apple backend needs no download; MLX backend downloads Gemma with progress. All inference is on-device/offline thereafter
- [x] Chunked map-reduce: transcripts >1800 tokens split into chunks, each summarized, then reduced (`TranscriptChunker` + `Summarizer`)
- [x] Map prompt: `Prompts/summarize-meeting.md` (map section); reduce prompt: same file (reduce section)
- [x] Action extraction uses `Prompts/extract-actions.md`; output is `[{owner?, task, due?, source_quote}]` (`ExtractedAction`)
- [x] JSON output validated against `ExtractedAction`/`MeetingSummary` Codable schema
- [x] On JSON parse failure: retry once with `Prompts/repair-json.md`; on second failure: degrade to summary-only and set `error` field on meeting row
- [x] `actions.json` written to meeting folder; `notes.md` written with summary + decisions + actions (`ArtifactWriter` + `NotesRenderer`)
- [x] Action owners are constrained to attendee names or "Unassigned" (`OwnerConstraint`)
- [~] Peak memory during LLM inference <6 GB — bounded by 4-bit Gemma 4 E4B (~3–4 GB) + sequential chunking; not yet profiled on-device
- [x] Throttle generation when `ProcessInfo.processInfo.isLowPowerModeEnabled` (`MLXLLMClient` caps `maxTokens`; chunks run one-at-a-time)
- [x] State machine advances: `diarized → summarized`
- [ ] (P1) Mirror action items to Apple Reminders "Meeting Actions" list (off by default)
- [x] Integration test: fixture transcript → summary, decisions, ≥90% of planted action items extracted with correct owners (`SummarizerTests`)

## Key Files to Create

```
Services/
  Summarizer.swift          Actor; MLX model load + chunked map-reduce
  ActionExtractor.swift     JSON extraction + validation + repair
Prompts/
  summarize-meeting.md      map + reduce prompt sections
  extract-actions.md        action item extraction prompt + JSON schema
  name-speakers.md          (created in Phase 4)
  repair-json.md            JSON repair retry prompt
Tests/
  SummarizerTests.swift
Tests/Fixtures/
  sample-transcript.txt
  sample-actions-expected.json
```

## Key APIs / Dependencies

- `MLXLLM`, `MLXLMCommon` — see `docs/vendor/mlx-swift-lm.md`
- `ProcessInfo.processInfo.isLowPowerModeEnabled`
- `EventKit` Reminders (P1): `EKReminder`, `NSRemindersFullAccessUsageDescription`

## Risks

- LLM JSON discipline: schema + repair prompt + degrade path covers the common failure modes
- Context window limits on 4B models (~2048 tokens); map-reduce handles this but increases total inference time
