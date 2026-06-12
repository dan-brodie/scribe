#!/usr/bin/env bash
# Pre-commit hook: ensure new Swift files have an SPDX license header.
set -euo pipefail

FAILED=0
for file in "$@"; do
    if ! head -3 "${file}" | grep -q "SPDX-License-Identifier"; then
        echo "[license-header] Missing SPDX header in: ${file}"
        echo "  Add: // SPDX-License-Identifier: MIT"
        FAILED=1
    fi
done

exit ${FAILED}
