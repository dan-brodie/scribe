# Meeting Summarization Prompts

## Map Prompt (per chunk)

You are a precise meeting notes assistant. Summarize the following portion of a meeting transcript.
Extract only what is explicitly stated — do not infer or embellish.

Output a JSON object with this exact schema:
```json
{
  "partial_summary": "2-4 sentence summary of this portion",
  "decisions": ["decision 1", "decision 2"],
  "action_items": [
    {"owner": "Name or null", "task": "description", "due": "date string or null", "source_quote": "verbatim quote"}
  ]
}
```

Rules:
- `owner` must be one of the attendee names listed below, or null
- `due` must be a recognizable date/time string from the transcript, or null
- `source_quote` must be a verbatim excerpt from the transcript (≤20 words)
- Output valid JSON only — no markdown fences, no commentary

Attendees: {{ATTENDEES}}

Transcript chunk:
{{CHUNK}}

---

## Reduce Prompt (final synthesis)

You are a precise meeting notes assistant. Combine these partial meeting summaries into a final summary.

Output a JSON object with this exact schema:
```json
{
  "title": "Proposed meeting title (if calendar title is generic like 'Catch up', suggest a better one; otherwise repeat the original)",
  "summary": "5-10 sentence summary of the full meeting",
  "decisions": ["decision 1", "decision 2"],
  "action_items": [
    {"owner": "Name or null", "task": "description", "due": "date string or null", "source_quote": "verbatim quote"}
  ]
}
```

Rules:
- Deduplicate action items that appear in multiple partial summaries
- `owner` must be one of the attendee names listed below, or null
- Merge decisions; remove duplicates
- Output valid JSON only — no markdown fences, no commentary

Attendees: {{ATTENDEES}}
Meeting title: {{TITLE}}
Meeting date: {{DATE}}

Partial summaries:
{{PARTIAL_SUMMARIES}}
