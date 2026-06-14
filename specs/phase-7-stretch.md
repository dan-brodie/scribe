# Phase 7 — Stretch Goals

status: not-started

## Goal

Post-v1 enhancements, reframed around pluggable provider backends and a Google LLM:

1. Pluggable **calendar** and **notes-output** backends — Apple stays the default; a Google native
   option is offered on first run and switchable in Settings.
2. Google native integration: Google Calendar API + output notes to a Google Workspace (Docs) doc.
3. Next-meeting countdown shown in the menu bar (title + minutes until start).
4. Swap the Qwen LLM lineup for Google Gemma 4.

> **Dropped from the original backlog:** Apple Notes export (7a) and PDF export (7c) — out of scope.
> Live captions / mini-transcript remain deferred (tracked at the bottom).

## Items (not ordered)

### 7a — Provider abstraction (foundation for 7b/7c)
Introduce two protocols so the rest of the app is provider-agnostic:

- `CalendarProvider` — `meetings(in:) async throws -> [Meeting]`, change notifications.
  - `AppleCalendarProvider` (EventKit) — **default**, current behaviour.
  - `GoogleCalendarProvider` (7b).
- `NotesOutputProvider` — `export(_ note: MeetingNote) async throws -> ExportRef`.
  - `LocalFileProvider` (existing `FileExporter`) — **default**. Now writes **Markdown** (`notes.md`)
    instead of plain text (see "Cross-cutting" below).
  - `GoogleDocsProvider` (7b) — maps the same Markdown structure to Docs styles (headings, lists).

Provider selection persisted in settings; defaults remain **Apple calendar + local files**.
First-run onboarding gains a step offering Google native as an opt-in alternative.
Multiple notes-output targets may be enabled at once (e.g. local file *and* Google Doc).

### 7b — Google native integration
- **Calendar:** Google Calendar API via OAuth2 (`calendar.readonly`); richer `conferenceData`
  (Meet links) than EventKit. For users who don't sync Google into macOS Internet Accounts.
- **Docs output:** write the meeting note into a new Google Workspace doc via the Google Docs API
  (`drive.file` scope to create/own only app-created docs). Return the doc URL as the `ExportRef`.
- OAuth tokens stored in Keychain; transparent refresh.
- **License/CI note:** Google API client deps must pass `make check-licenses` (allowlist is
  MIT/Apache-2.0/BSD-class). Google's Swift/REST client libs are Apache-2.0 — OK.

### 7c — Next-meeting countdown in the menu bar
- Menu bar shows the next upcoming meeting and a live countdown ("Standup · in 12 min").
- Updates each minute (timer-driven; coalesce to avoid wake churn).
- Sourced from the active `CalendarProvider` (works for Apple/Google alike).
- Hidden / shows app name when no meeting is within a configurable look-ahead window.

### 7d — Swap LLM lineup to Google Gemma 4
- Replace Qwen/Llama with **Google Gemma 4 E4B** (4-bit MLX) — 4B effective params, ~2.5 GB,
  built for edge/mobile; direct swap for the current Qwen3-4B slot. **Decided: E4B is the default.**
  - Gemma 4 **E2B** (2B, ~0.84 GB) available as a lighter fallback for low-RAM machines.
- Update `Summarizer`, `Prompts/*` (Gemma chat template differs from Qwen), default model id,
  and `Scripts/download-models.sh`; update CLAUDE.md "Default LLM" line + ADR-1.
- **License: clean.** Gemma 4 weights are **Apache-2.0 and not gated** (freely downloadable from
  Hugging Face / Kaggle). Passes `make check-licenses` and satisfies the "no gated weights" rule —
  no policy change needed. (Earlier Gemma generations used the Gemma Terms of Use; Gemma 4 does not.)

## Cross-cutting — Markdown output format
**Decided:** notes are emitted as **Markdown**, replacing the current plain-text format.
- `FileExporter` writes `notes.md` (was `notes.txt`); use `#`/`##` headings, `-` bullets for
  actions, bold owners, etc. JSON sidecar is unchanged.
- Update prompt templates (`Prompts/*`) so the LLM emits Markdown-friendly section structure.
- The share email (`Sharer`) sends the Markdown body; consider a rendered vs. raw toggle.
- This supersedes **ADR-3** ("Plain text + JSON") → update ADR-3 and the CLAUDE.md "Output format"
  references. Touches already-shipped Phase 6 code, so it lands as part of this phase.
- `GoogleDocsProvider` (7b) consumes the same Markdown to apply native Docs styles.

## Deferred (not in this phase)
- Live caption window (`StreamingEouAsrManager`, floating `NSPanel`).
- Menu-bar mini-transcript (last N speaker turns), driven by the streaming ASR feed.

## Dependencies & sequencing
- **7a is the foundation** — 7b plugs into it; build it first.
- 7c depends only on the `CalendarProvider` protocol from 7a.
- 7d (Gemma 4) is independent of 7a–7c; can be done any time.

## Open questions
1. Multiple simultaneous notes outputs — confirm UX (default off for cloud targets, consent-gated).
2. Share email: send raw Markdown or HTML-rendered body?
