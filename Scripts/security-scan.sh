#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Local secret scan over the working tree, mirroring the gitleaks CI gate.
# Install once with: brew install gitleaks
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "[SKIP] gitleaks not installed — run 'brew install gitleaks' to enable."
    echo "       CI runs this check on every push regardless."
    exit 0
fi

echo "Running gitleaks over the working tree…"
# --no-banner keeps output clean; redact secrets in any finding.
gitleaks detect --source . --redact --verbose --config "${ROOT}/.gitleaks.toml"
echo "[PASS] no secrets detected."
