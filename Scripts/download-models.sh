#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Scribe model downloads happen IN-APP, not in this script:
#
#   - Parakeet ASR (FluidAudio ModelRegistry): downloaded on first use or from
#     the onboarding "Download models" step, with progress UI. Integrity is
#     tracked with a SHA-256 manifest — see Services/ModelDownloader.swift.
#     A checksum mismatch is re-downloaded once and then surfaced as an error.
#
#   - Gemma (MLX, mlx-community/gemma-4-E4B-it-qat-4bit): downloaded by the
#     Hugging Face loader when the MLX summarization backend is selected —
#     see Services/MLXLLMClient.swift.
#
# This script exists so `make download-models` has a discoverable home; it
# intentionally performs no network fetches of its own (an earlier version
# carried unused checksum/download helpers, which was misleading).
# ---------------------------------------------------------------------------

echo "Scribe models are downloaded in-app with progress UI and integrity checks:"
echo "  - ASR (Parakeet): onboarding 'Download models' step, or first transcription"
echo "  - LLM (Gemma, optional): first summarization with the MLX backend selected"
echo ""
echo "Nothing to do here. Launch Scribe to trigger the downloads."
