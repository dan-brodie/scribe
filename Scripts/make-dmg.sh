#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build a styled, drag-to-Applications DMG for Scribe.
#
# Usage: bash Scripts/make-dmg.sh [path/to/Scribe.app]
# Default app path matches `make release` output (build/.../Release/Scribe.app).
# Output: dist/Scribe-<version>.dmg
#
# No external tooling required — uses hdiutil + Finder (osascript) only. If the
# Finder styling step can't run (e.g. headless CI), it falls back to a plain but
# functional DMG.
# ---------------------------------------------------------------------------

APP_PATH="${1:-build/Build/Products/Release/Scribe.app}"
APP_NAME="Scribe"
VOL_NAME="Scribe"
DIST_DIR="dist"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: ${APP_PATH} not found — run 'make release' first." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

DMG_FINAL="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_TMP="${DIST_DIR}/.${APP_NAME}-tmp.dmg"
STAGE_DIR=$(mktemp -d)

echo "Packaging ${APP_NAME} ${VERSION}"
echo "  app:    ${APP_PATH}"
echo "  output: ${DMG_FINAL}"

cleanup() { rm -rf "${STAGE_DIR}" "${DMG_TMP}"; }
trap cleanup EXIT

mkdir -p "${DIST_DIR}"
rm -f "${DMG_FINAL}" "${DMG_TMP}"

# Stage the app and a symlink to /Applications (the classic drag target).
cp -R "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

# Ship the license notices alongside the app to satisfy the MIT/Apache/BSD
# attribution requirements of bundled dependencies.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "${STAGE_DIR}/LICENSE.txt"
[[ -f "${REPO_ROOT}/THIRD-PARTY-LICENSES.md" ]] && \
    cp "${REPO_ROOT}/THIRD-PARTY-LICENSES.md" "${STAGE_DIR}/THIRD-PARTY-LICENSES.md"

# Create a writable DMG we can style, sized to the staged content + headroom.
SIZE_KB=$(du -sk "${STAGE_DIR}" | awk '{print $1}')
SIZE_MB=$(( SIZE_KB / 1024 + 64 ))
hdiutil create -srcfolder "${STAGE_DIR}" -volname "${VOL_NAME}" \
    -fs HFS+ -format UDRW -size "${SIZE_MB}m" "${DMG_TMP}" >/dev/null

# Mount and arrange the Finder window: icon view, app on the left, Applications
# on the right, so the layout reads "drag Scribe → Applications".
MOUNT_DIR="/Volumes/${VOL_NAME}"
hdiutil attach "${DMG_TMP}" -mountpoint "${MOUNT_DIR}" -nobrowse -noautoopen >/dev/null

if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 700, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "${APP_NAME}.app" of container window to {130, 170}
        set position of item "Applications" of container window to {370, 170}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF
then
    echo "  styled Finder layout applied"
else
    echo "  warning: Finder styling skipped (non-interactive?) — DMG still works"
fi

sync
hdiutil detach "${MOUNT_DIR}" >/dev/null || hdiutil detach "${MOUNT_DIR}" -force >/dev/null

# Convert to a compressed, read-only DMG for distribution.
hdiutil convert "${DMG_TMP}" -format UDZO -imagekey zlib-level=9 \
    -o "${DMG_FINAL}" >/dev/null

echo "Done: ${DMG_FINAL}"
