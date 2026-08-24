#!/usr/bin/env bash
#
# Package a Factorio mod for upload to the mod portal.
#
# Zips factorio/mods/<mod-name>/ into dist/<mod-name>_<version>.zip with the
# portal-required layout (root folder "<name>_<version>") and excludes
# development-only files (tests/, dotfiles, backups).
#
# Usage:
#   tools/package-mod.sh [mod-dir]          # default: custom-spawn-rates
#   tools/package-mod.sh --out <dir> [mod]  # override output directory
#
# Requires: zip, unzip (listing), grep -P   (see Dockerfile)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODS_DIR="$REPO_ROOT/factorio/mods"
OUT_DIR="$REPO_ROOT/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out|-o) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,11p' "$0"; exit 0 ;;
    *) break ;;
  esac
done

MOD="${1:-custom-spawn-rates}"
SRC_DIR="$MODS_DIR/$MOD"
[[ -d "$SRC_DIR" ]] || { echo "error: no such mod directory: $SRC_DIR" >&2; exit 1; }
[[ -f "$SRC_DIR/info.json" ]] || { echo "error: $SRC_DIR has no info.json" >&2; exit 1; }

# Fields are one-per-line in our info.json; grep suffices, no JSON parser needed.
json_field() {
    local field="$1"
    grep -oP '"'$field'"\s*:\s*"\K[^"]+' "$SRC_DIR/info.json" | head -n1
}
NAME="$(json_field name)"
VERSION="$(json_field version)"
[[ -n "$NAME" && -n "$VERSION" ]] || {
    echo "error: could not read name/version from $SRC_DIR/info.json" >&2; exit 1;
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/${NAME}_${VERSION}"
mkdir -p "$PKG"

# Copy everything, then drop dev-only files; keep locale/ and any assets.
cp -a "$SRC_DIR/." "$PKG/"
rm -rf \
    "$PKG/tests" \
    "$PKG"/.git* \
    "$PKG"/*.bak \
    "$PKG"/*.orig \
    "$PKG"/*.swp

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/${NAME}_${VERSION}.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ZIP" "${NAME}_${VERSION}")

echo "packaged $MOD $VERSION -> $ZIP"
unzip -l "$ZIP"
