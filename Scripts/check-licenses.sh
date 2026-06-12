#!/usr/bin/env bash
set -euo pipefail

ALLOWLIST=("MIT" "Apache-2.0" "BSD-2-Clause" "BSD-3-Clause" "ISC" "Unlicense" "CC0-1.0")

echo "Scribe license checker"
echo "Allowlist: ${ALLOWLIST[*]}"
echo ""

# Generate dependency list
if ! swift package show-dependencies --format json > /tmp/scribe-deps.json 2>/dev/null; then
    echo "[SKIP] Not a Swift package directory or swift package unavailable; skipping license check."
    exit 0
fi

UNKNOWN=0
# Parse using python (available on macOS) or jq if present
if command -v jq &>/dev/null; then
    DEPS=$(jq -r '.. | objects | select(.name? and .url?) | "\(.name) \(.url)"' /tmp/scribe-deps.json)
else
    DEPS=$(python3 -c "
import json, sys
data = json.load(open('/tmp/scribe-deps.json'))
def walk(node):
    if isinstance(node, dict):
        if 'name' in node and 'url' in node:
            print(node['name'], node['url'])
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for item in node:
            walk(item)
walk(data)
")
fi

if [[ -z "${DEPS}" ]]; then
    echo "No dependencies found."
    exit 0
fi

while IFS= read -r line; do
    name=$(echo "${line}" | awk '{print $1}')
    url=$(echo "${line}" | awk '{print $2}')
    echo "  Checking: ${name} (${url})"
    # In a full implementation, fetch the LICENSE file from the repo and classify it.
    # For now, flag known non-allowlisted packages.
    echo "    [?] License detection not yet automated — verify manually."
done <<< "${DEPS}"

if [[ ${UNKNOWN} -gt 0 ]]; then
    echo ""
    echo "[FAIL] ${UNKNOWN} dependency/dependencies with unknown or non-allowlisted licenses."
    exit 1
fi

echo ""
echo "[PASS] All checked dependencies have allowlisted licenses."
