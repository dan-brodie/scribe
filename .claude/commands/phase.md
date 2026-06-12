Show current implementation status across all phases.

Run: grep -n "^status:" specs/phase-*.md

Then render a table:
| Phase | File | Status |
listing each phase spec and its status value (not-started / in-progress / complete).
