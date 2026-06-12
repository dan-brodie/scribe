# Phase 5 — Summarization & Action Extraction (MLX)

status: not-started

## Goal

Generate meeting summary, decisions, and structured action items from the diarized transcript using a local MLX LLM, with chunked map-reduce for long meetings.

## Acceptance Criteria

- [ ] `Summarizer` loads `MLXLLM` model via `LLMModelFactory`; default `Qwen/Qwen3-4B-Instruct` 4-bit
- [ ] First run downloads model with progress; all subsequent inference is offline
- [ ] Chunked map-reduce: transcripts >1800 tokens split into chunks, each summarized, then reduced
- [ ] Map prompt: `Prompts/summarize-meeting.md` (map section); reduce prompt: same file (reduce section)
- [ ] Action extraction uses `Prompts/extract-actions.md`; output is `[{owner?, task, due?, sourceQuote}]`
- [ ] JSON output validated against `ActionItem` Codable schema
- [ ] On JSON parse failure: retry once with `Prompts/repair-json.md`; on second failure: degrade to summary-only and set `error` field on meeting row
- [ ] `actions.json` written to meeting folder; `notes.txt` written with summary + decisions + actions
- [ ] Action owners are constrained to attendee names or "Unassigned"
- [ ] Peak memory during LLM inference <6 GB
- [ ] Throttle batch size when `ProcessInfo.processInfo.isLowPowerModeEnabled`
- [ ] State machine advances: `diarized → summarized`
- [ ] (P1) Mirror action items to Apple Reminders "Meeting Actions" list (off by default)
- [ ] Integration test: fixture transcript → summary, decisions, ≥90% of planted action items extracted with correct owners

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
