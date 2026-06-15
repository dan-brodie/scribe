# Scribe

A macOS menu bar app that automatically records your mic + system audio during Google
Calendar meetings, then transcribes, diarizes, and summarizes them **entirely on-device**
(Apple Silicon). Markdown notes and action items are written to a local folder — no cloud,
no accounts beyond what macOS already syncs.

See [`CLAUDE.md`](CLAUDE.md) for architecture, ADRs, and the phase backlog.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 14.4 or later
- Xcode 15.3+ with command-line tools (`xcode-select --install`)
- A Google account added to **System Settings → Internet Accounts** with Calendar enabled

## Install

### Homebrew (recommended)

```bash
brew install --cask dan-brodie/tap/scribe
```

The app launches cleanly — the [tap](https://github.com/dan-brodie/homebrew-tap)'s
cask clears the download quarantine flag (Scribe is ad-hoc signed, not notarized).
Upgrade with `brew upgrade --cask scribe`.

### Download the DMG

Grab the latest `.dmg` from [Releases](https://github.com/dan-brodie/scribe/releases),
open it, and drag **Scribe** to **Applications**. Because the app isn't notarized,
the first launch needs **right-click → Open** (or `xattr -dr com.apple.quarantine
/Applications/Scribe.app`).

## Build from source

```bash
# 1. Fetch the on-device models (Gemma 4 E4B + Parakeet) — first run only, several GB
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
make dmg       # Release build packaged as a drag-to-Applications DMG in dist/
make test      # run the unit + integration test suite
make clean     # remove build artifacts
```

Run `make help` to list all targets.

## License

Scribe is released under the [MIT License](LICENSE).

It links several open-source packages (FluidAudio, MLX, GRDB, Apple Swift libraries,
Hugging Face Swift libraries, and others) under permissive MIT / Apache-2.0 / BSD-class
licenses. Their full notices are reproduced in [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)
(regenerate with `make attributions`); the DMG ships this file alongside the app. A CI gate
(`make check-licenses`) fails the build if a dependency carries a non-allowlisted license.

Model weights are downloaded at runtime, not bundled: **Google Gemma 4** (Apache-2.0) and
**NVIDIA Parakeet** via FluidAudio (permissive).

## Notes

- The app is built unsigned for local use. The first launch may be blocked by Gatekeeper —
  right-click `Scribe.app` → **Open**, or allow it under System Settings → Privacy & Security.
- All processing runs locally; no audio or transcripts leave your machine.
