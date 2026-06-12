# ADR-005: Speaker Naming — Heuristic Pipeline, Design for Correction

## Status
Accepted

## Context
Diarization yields anonymous speakers (SPEAKER_1…N). Mapping them to names is hard and will sometimes be wrong. Must be confidence-scored and user-correctable, never presented as ground truth.

## Decision
Pipeline (ordered by signal strength):

1. **Channel prior** — speech dominant on the mic channel → local user (from EventKit `currentUser`)
2. **Self-introduction & address cues** — LLM scans transcript for cues ("Hi, it's Priya", "Thanks John") and proposes name↔speaker mappings with confidence scores, constrained to the invitee list
3. **Count matching** — if detected speaker count == attendee count, propose best-guess assignment; otherwise leave unmatched as `Speaker N`
4. **Voice enrollment (persistent)** — store embeddings (FluidAudio embedding extractor) per confirmed person; cosine-match in later meetings; strongest signal over time. Off by default behind "Remember voices" toggle.
5. **UI correction** — Review popover lets user reassign names in 2 clicks; corrections update enrollment library

Every assignment carries: `confidence` (high/medium/low) and `provenance` (channel/cue/enrollment/count-match).

## Consequences
- Output is always best-effort; UI makes this clear
- Voice enrollment stores biometric-ish data — must be deletable (Settings → "Delete voice profiles")
- Open question (resolve before Phase 4): ship enrollment in v1?
