# Phase 4 — Diarization & Speaker Naming

status: not-started

## Goal

Attribute transcript segments to named speakers using FluidAudio diarization, LLM cue extraction, and a user-correctable Review popover.

## Acceptance Criteria

- [ ] `Diarizer` runs FluidAudio `OfflineDiarizerManager` on the system-audio channel
- [ ] Mic channel's dominant speaker is assigned to the local user (channel prior, ADR-005)
- [ ] Speaker timelines from both channels merged; overlaps resolved by channel energy
- [ ] `SpeakerNamer` calls LLM with `Prompts/name-speakers.md` prompt, constrained to attendee list, returns `[{speakerLabel, attendeeEmail, confidence, provenance}]`
- [ ] Count-match fallback: if diarized speaker count == attendee count, propose best-guess assignment
- [ ] All assignments stored in `speakers` table with `confidence` and `provenance` columns
- [ ] Review popover accessible from menu; shows each speaker with 5 s audio snippet + attendee dropdown
- [ ] Reassigning a speaker in the popover rewrites `transcript.txt` and `actions.json` atomically
- [ ] State machine advances: `transcribed → diarized`
- [ ] Integration test: 3-speaker fixture with scripted self-introductions → ≥2/3 auto-named correctly
- [ ] (P1) Voice enrollment: `voiceProfiles` table populated after user confirms a name; cosine-match on subsequent meetings; off by default behind "Remember voices" toggle in Settings

## Open Questions (answer before starting)

1. Ship voice enrollment in v1? (Recommended: yes, behind off-by-default toggle)
2. What confidence threshold triggers auto-assignment vs. always-ask?

## Key Files to Create

```
Services/
  Diarizer.swift            Actor; FluidAudio OfflineDiarizerManager wrapper
  SpeakerNamer.swift        heuristic pipeline: channel prior + LLM cues + enrollment
  VoiceEnrollmentStore.swift  embedding storage + cosine similarity (P1)
App/
  ReviewPopover.swift       speaker reassignment UI
Tests/
  DiarizerTests.swift
Tests/Fixtures/
  sample-3speaker.wav
  sample-3speaker-reference.json
```

## Key APIs / Dependencies

- FluidAudio `OfflineDiarizerManager`, `DiarizerManager` (embeddings) — see `docs/vendor/fluidaudio.md`
- LLM via `MLXLLM` + `Prompts/name-speakers.md`
- `AVAudioPlayer` for 5 s snippet playback in Review popover

## Risks

- Diarization quality degrades on far-field/echoey audio; dual-channel design is the primary mitigation
- LLM name inference may hallucinate names not in the attendee list — strictly filter output to the provided list
