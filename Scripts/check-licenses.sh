#!/usr/bin/env bash
set -euo pipefail

# Fails if any resolved SPM dependency is unclassified or carries a license
# outside the allowlist in Scripts/licenses.json. The set of dependencies is
# read from the Xcode workspace's Package.resolved (the source of truth for what
# is actually linked); falls back to `swift package` for a plain SPM checkout.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST_JSON="${ROOT}/Scripts/licenses.json"
RESOLVED="${ROOT}/Scribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

echo "Scribe license checker"

if [[ ! -f "${ALLOWLIST_JSON}" ]]; then
    echo "[FAIL] missing allowlist: ${ALLOWLIST_JSON}"
    exit 1
fi

# Collect resolved dependency identities. Prefer Package.resolved; otherwise try
# `swift package show-dependencies` for a non-Xcode checkout.
if [[ -f "${RESOLVED}" ]]; then
    SOURCE="${RESOLVED}"
elif swift package show-dependencies --format json > /tmp/scribe-deps.json 2>/dev/null; then
    SOURCE="/tmp/scribe-deps.json"
else
    echo "[SKIP] no Package.resolved and swift package unavailable; skipping."
    exit 0
fi

python3 - "${ALLOWLIST_JSON}" "${SOURCE}" <<'PY'
import json
import sys

allowlist_path, source_path = sys.argv[1], sys.argv[2]

spec = json.load(open(allowlist_path))
allowed = set(spec.get("allowed_spdx", []))
known = {k.lower(): v for k, v in spec.get("dependencies", {}).items()}

data = json.load(open(source_path))

# Package.resolved (v2/v3) has top-level "pins"; show-dependencies output nests
# "identity"/"name" through a tree. Handle both.
identities = set()
if isinstance(data, dict) and "pins" in data:
    for pin in data["pins"]:
        identities.add(pin["identity"].lower())
elif isinstance(data, dict) and "object" in data and "pins" in data["object"]:
    for pin in data["object"]["pins"]:
        identities.add(pin["identity"].lower())
else:
    def walk(node):
        if isinstance(node, dict):
            ident = node.get("identity") or node.get("name")
            if ident:
                identities.add(str(ident).lower())
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(data)

print(f"Allowlist: {', '.join(sorted(allowed))}")
print(f"Dependencies resolved: {len(identities)}\n")

failures = []
for ident in sorted(identities):
    license = known.get(ident)
    if license is None:
        print(f"  [?] {ident}: UNCLASSIFIED — add it to Scripts/licenses.json")
        failures.append(ident)
    elif license not in allowed:
        print(f"  [x] {ident}: {license} — not in allowlist")
        failures.append(ident)
    else:
        print(f"  [ok] {ident}: {license}")

if failures:
    print(f"\n[FAIL] {len(failures)} dependency/dependencies need attention.")
    sys.exit(1)

print("\n[PASS] All resolved dependencies have allowlisted licenses.")
PY
