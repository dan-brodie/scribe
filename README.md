# Scribe

A macOS menu bar app that automatically records your mic + system audio during Google
Calendar meetings, then transcribes, diarizes, and summarizes them **entirely on-device**
(Apple Silicon). Plain-text notes and action items are written to a local folder — no cloud,
no accounts beyond what macOS already syncs.

See [`CLAUDE.md`](CLAUDE.md) for architecture, ADRs, and the phase backlog.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 14.4 or later
- Xcode 15.3+ with command-line tools (`xcode-select --install`)
- A Google account added to **System Settings → Internet Accounts** with Calendar enabled

## Build & Install

```bash
# 1. Fetch the on-device models (Qwen3-4B + Parakeet) — first run only, several GB
make download-models

# 2. Build a Release app and copy it to /Applications
make install
```

`make install` builds `Scribe.app` into `build/` and copies it to `/Applications`. Then launch it:

```bash
open /Applications/Scribe.app
```

Scribe is a menu bar app (no Dock icon) — look for its icon in the menu bar after launch.
On first run it walks you through granting Microphone, System Audio Recording, and Calendar
permissions.

### Other build targets

```bash
make build     # Debug build (default DerivedData location), for development
make release   # Release build into build/, without installing
make test      # run the unit + integration test suite
make clean     # remove build artifacts
```

Run `make help` to list all targets.

## Notes

- The app is built unsigned for local use. The first launch may be blocked by Gatekeeper —
  right-click `Scribe.app` → **Open**, or allow it under System Settings → Privacy & Security.
- All processing runs locally; no audio or transcripts leave your machine.
