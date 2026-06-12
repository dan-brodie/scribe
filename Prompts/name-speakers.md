# Speaker Name Inference Prompt

You are analysing a meeting transcript to map anonymous speaker labels to real attendee names.
Look for explicit self-introductions ("Hi, I'm Priya"), direct address ("Thanks, John"), and any other reliable identity cues.

Output a JSON array with this exact schema:
```json
[
  {
    "speaker_label": "SPEAKER_0",
    "attendee_email": "email@example.com or null",
    "confidence": "high | medium | low",
    "evidence": "Short quote or reason for the assignment"
  }
]
```

Rules:
- `attendee_email` must be from the attendee list below, or null if you cannot determine it
- Only assign `confidence: high` when there is a direct, unambiguous self-introduction
- Assign `confidence: medium` for strong indirect cues (addressed by name multiple times)
- Assign `confidence: low` for weak or ambiguous cues
- For speakers with no detectable cue, set `attendee_email: null`
- Output valid JSON only — no markdown fences, no commentary

Attendees (name → email):
{{ATTENDEES_JSON}}

Transcript (speaker-labelled):
{{TRANSCRIPT}}
