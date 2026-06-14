#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${HOME}/.cache/scribe-models"
HF_BASE="https://huggingface.co"

echo "Scribe model downloader"
echo "Target: ${CACHE_DIR}"
mkdir -p "${CACHE_DIR}"

# ---------------------------------------------------------------------------
# Helper: download a file with checksum verification
# ---------------------------------------------------------------------------
download_file() {
    local url="$1"
    local dest="$2"
    local expected_sha256="$3"

    if [[ -f "${dest}" ]]; then
        local actual
        actual=$(shasum -a 256 "${dest}" | awk '{print $1}')
        if [[ "${actual}" == "${expected_sha256}" ]]; then
            echo "  [ok] $(basename "${dest}") — already downloaded and verified"
            return 0
        else
            echo "  [!] $(basename "${dest}") — checksum mismatch, re-downloading"
            rm -f "${dest}"
        fi
    fi

    echo "  [->] Downloading $(basename "${dest}")..."
    curl -fL --progress-bar -o "${dest}" "${url}"

    local actual
    actual=$(shasum -a 256 "${dest}" | awk '{print $1}')
    if [[ "${actual}" != "${expected_sha256}" ]]; then
        echo "  [ERROR] Checksum mismatch for $(basename "${dest}")"
        echo "          Expected: ${expected_sha256}"
        echo "          Got:      ${actual}"
        rm -f "${dest}"
        exit 1
    fi
    echo "  [ok] $(basename "${dest}") — verified"
}

# ---------------------------------------------------------------------------
# FluidAudio will auto-download Parakeet on first use via ModelRegistry.
# This script pre-warms the cache so the first meeting doesn't stall.
# ---------------------------------------------------------------------------
echo ""
echo "NOTE: FluidAudio models (Parakeet TDT) are downloaded automatically by"
echo "the app on first use via ModelRegistry. This script pre-warms the MLX"
echo "LLM weights only."
echo ""

# ---------------------------------------------------------------------------
# Gemma 4 E4B Instruct 4-bit (default LLM) — Apache-2.0, ungated
# Update checksums from: https://huggingface.co/mlx-community/gemma-4-E4B-it-qat-4bit/tree/main
# ---------------------------------------------------------------------------
GEMMA_DIR="${CACHE_DIR}/gemma-4-E4B-it-qat-4bit"
mkdir -p "${GEMMA_DIR}"

echo "Downloading Gemma 4 E4B Instruct (4-bit)..."
echo "  Note: Update checksums in this script after verifying from HuggingFace."
echo "  Skipping automatic download — run the app to trigger MLX model download."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Done. Models cached at: ${CACHE_DIR}"
echo "Run the app and open Settings → Models to trigger in-app downloads with progress UI."
