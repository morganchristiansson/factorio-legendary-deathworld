#!/usr/bin/env bash
#
# Update the scenario Lua inside existing Factorio save zip(s) from
# factorio/scenarios/<name>/. The save's level data is left byte-for-byte
# untouched -- only scenario entries are replaced.
#
# Usage:
#   tools/update-lua-in-save.sh <save.zip> [more-saves.zip...]
#   tools/update-lua-in-save.sh --dry-run <save.zip>
#
# Requires: zip, unzip   (see Dockerfile)
#
# IMPORTANT: the Factorio server must be STOPPED before running this.
# Stopping the server writes its final state into the save; updating the zip
# while the server runs means your changes get overwritten by that final
# write. This script refuses to run if a factorio process is detected.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO_DIR="$REPO_ROOT/factorio/scenarios/Legendary Deathworld"

DRY_RUN=0
SAVES=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed '1d' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SAVES+=("$arg") ;;
  esac
done
if [[ ${#SAVES[@]} -eq 0 ]]; then
  echo "error: no save file given (try --help)" >&2
  exit 2
fi

command -v zip >/dev/null || { echo "error: 'zip' not installed"; exit 1; }
command -v unzip >/dev/null || { echo "error: 'unzip' not installed"; exit 1; }
[[ -d "$SCENARIO_DIR" ]] || { echo "error: scenario dir not found: $SCENARIO_DIR"; exit 1; }

# Files we sync into the save. info.json is deliberately excluded: it is
# save metadata written by Factorio, not scenario payload.
# All top-level *.lua are picked up automatically, so adding a module
# (e.g. reset.lua) needs no script changes.
shopt -s nullglob
cd "$SCENARIO_DIR"
SYNC_FILES=(*.lua description.json locale/en/freeplay.cfg)
cd "$REPO_ROOT"
(( ${#SYNC_FILES[@]} > 2 )) || { echo "error: no .lua files found in $SCENARIO_DIR" >&2; exit 1; }

if pgrep -x factorio >/dev/null 2>&1; then
  echo "error: a factorio process appears to be running."
  echo "       Stop the server first (its shutdown save must land before we edit the zip)."
  exit 1
fi

fail() { echo "error: $*" >&2; exit 1; }

# Echo the single top-level folder used inside the save zip.
inner_folder() {
  local top
  top=$(sed 's#/.*##' <<<"$1" | sort -u)
  if [[ "$(echo "$top" | wc -l)" != "1" || -z "$top" ]]; then
    fail "cannot auto-detect inner folder (top-level entries: $(echo "$top" | tr '\n' ' '))"
  fi
  echo "$top"
}

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

for SAVE in "${SAVES[@]}"; do
  [[ -f "$SAVE" ]] || fail "no such file: $SAVE"
  SAVE="$(cd "$(dirname "$SAVE")" && pwd)/$(basename "$SAVE")"
  LISTING=$(unzip -Z1 "$SAVE")
  FOLDER=$(inner_folder "$LISTING")
  grep -qx "$FOLDER/freeplay.lua" <<<"$LISTING" \
    || fail "'$FOLDER/freeplay.lua' not found in '$SAVE' -- not a scenario save?"

  echo "== $SAVE (inner folder: $FOLDER/)"

  # Stage current scenario files under the save's own folder name.
  for f in "${SYNC_FILES[@]}"; do
    mkdir -p "$STAGING/$(dirname "$FOLDER/$f")"
    cp "$SCENARIO_DIR/$f" "$STAGING/$FOLDER/$f"
  done

  if (( DRY_RUN )); then
    for f in "${SYNC_FILES[@]}"; do
      if unzip -p "$SAVE" "$FOLDER/$f" | cmp -s - "$STAGING/$FOLDER/$f"; then
        echo "   unchanged: $f"
      else
        echo "   would update: $f ($(unzip -p "$SAVE" "$FOLDER/$f" | wc -c) -> $(wc -c < "$STAGING/$FOLDER/$f") bytes)"
      fi
    done
    continue
  fi

  BACKUP="${SAVE%.zip}.bak-$(date +%Y%m%d%H%M%S).zip"
  cp -p "$SAVE" "$BACKUP"

  ( cd "$STAGING" && zip -q "$SAVE" "${SYNC_FILES[@]/#/$FOLDER/}" )

  # Verify: archive intact and every synced entry matches what we staged.
  unzip -tqq "$SAVE" || fail "post-update integrity check failed for '$SAVE'"
  for f in "${SYNC_FILES[@]}"; do
    unzip -p "$SAVE" "$FOLDER/$f" | cmp -s - "$STAGING/$FOLDER/$f" \
      || fail "verification failed for $FOLDER/$f in '$SAVE'"
  done

  echo "   updated: ${SYNC_FILES[*]}"
  echo "   backup:  $BACKUP"
done
