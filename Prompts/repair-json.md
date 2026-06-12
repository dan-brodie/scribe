# JSON Repair Prompt

The following text was supposed to be valid JSON but failed to parse. Fix it.

Common issues to correct:
- Trailing commas before `}` or `]`
- Unescaped quotes inside string values
- Missing closing brackets or braces
- Non-JSON preamble or postamble text (strip it)
- Truncated output (complete the structure if clearly truncated)

Output only the corrected JSON — no explanation, no markdown fences.

Broken JSON:
{{BROKEN_JSON}}
