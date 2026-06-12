#!/usr/bin/env bash
# Fetch audio test fixtures for the ASR integration test.
#
# The integration test needs a public-domain speech clip and its reference
# transcript. Set FIXTURE_WAV_URL / FIXTURE_TXT_URL to a CC0/public-domain
# source (e.g. a LibriVox chapter) to download them; otherwise this prints
# instructions and exits 0 so the build is never blocked.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures"
WAV="${FIXTURE_DIR}/sample-10min.wav"
TXT="${FIXTURE_DIR}/sample-10min-reference.txt"

mkdir -p "${FIXTURE_DIR}"

if [[ -f "${WAV}" && -f "${TXT}" ]]; then
    echo "[fixtures] Already present:"
    echo "  ${WAV}"
    echo "  ${TXT}"
    exit 0
fi

if [[ -n "${FIXTURE_WAV_URL:-}" && -n "${FIXTURE_TXT_URL:-}" ]]; then
    echo "[fixtures] Downloading from configured URLs…"
    curl -fsSL "${FIXTURE_WAV_URL}" -o "${WAV}"
    curl -fsSL "${FIXTURE_TXT_URL}" -o "${TXT}"
    echo "[fixtures] Done."
    exit 0
fi

cat <<EOF
[fixtures] No fixture URLs configured — nothing downloaded.

To enable the ASR integration test (ASREngineTests.testFixtureTranscription…):

  1. Obtain a public-domain / CC0 speech clip (~10 min) and its transcript.
     LibriVox (https://librivox.org) recordings are public domain.
  2. Place them at:
       ${WAV}
       ${TXT}
     or set FIXTURE_WAV_URL and FIXTURE_TXT_URL and re-run:
       FIXTURE_WAV_URL=… FIXTURE_TXT_URL=… make download-fixtures

The test is skipped (not failed) while these are absent.
EOF
