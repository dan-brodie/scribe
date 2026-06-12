#!/usr/bin/env bash
# Pre-commit hook: block accidental audio file commits.
# Invoked by pre-commit with staged filenames as arguments.

set -euo pipefail

AUDIO_EXTENSIONS=("caf" "wav" "mp3" "m4a" "aiff" "aac" "flac" "ogg")
VIOLATIONS=0

for file in "$@"; do
  ext="${file##*.}"
  ext_lower="${ext,,}"
  for blocked in "${AUDIO_EXTENSIONS[@]}"; do
    if [[ "$ext_lower" == "$blocked" ]]; then
      echo "ERROR: Blocked audio file: ${file}"
      echo "  Audio files must not be committed. Add to .gitignore or use Tests/Fixtures/ with a .gitkeep."
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done
done

if [[ $VIOLATIONS -gt 0 ]]; then
  exit 1
fi
