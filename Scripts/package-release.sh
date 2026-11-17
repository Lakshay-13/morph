#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${MORPH_VERSION:-0.1.0}"
DIST_ROOT="${MORPH_DIST_DIR:-$REPO_ROOT/dist}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  printf 'MORPH_VERSION must be a safe semantic version (received %s).\n' "$VERSION" >&2
  exit 2
fi
export MORPH_BUILD_ARCH=universal
export MORPH_DIST_DIR="$DIST_ROOT"
export MORPH_VERSION="$VERSION"
"$REPO_ROOT/Scripts/build-app.sh"

ARCHIVE="$DIST_ROOT/Morph-$VERSION-macOS-universal.zip"
STAGE="$DIST_ROOT/Morph-$VERSION"
if [[ -e "$ARCHIVE" ]]; then
  printf 'Refusing to overwrite existing archive: %s\n' "$ARCHIVE" >&2
  exit 1
fi
if [[ -e "$STAGE" ]]; then
  printf 'Refusing to overwrite release staging directory: %s\n' "$STAGE" >&2
  exit 1
fi
mkdir -p "$STAGE"
trap 'rm -r "$STAGE"' EXIT
ditto "$DIST_ROOT/Morph.app" "$STAGE/Morph.app"
ditto "$REPO_ROOT/Resources/QuickActions/Convert with Morph.workflow" "$STAGE/Convert with Morph.workflow"
cp "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"
cp "$REPO_ROOT/docs/THIRD_PARTY.md" "$STAGE/THIRD_PARTY.md"
ditto "$REPO_ROOT/THIRD_PARTY_LICENSES" "$STAGE/THIRD_PARTY_LICENSES"
ditto -c -k --norsrc --keepParent "$STAGE" "$ARCHIVE"
if [[ -n "${MORPH_CODESIGN_IDENTITY:-}" && -n "${MORPH_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$MORPH_NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/Morph.app"
  xcrun stapler validate "$STAGE/Morph.app"
  codesign --verify --deep --strict --verbose=2 "$STAGE/Morph.app"
  spctl --assess --type execute --verbose=2 "$STAGE/Morph.app"
  rm "$ARCHIVE"
  ditto -c -k --norsrc --keepParent "$STAGE" "$ARCHIVE"
elif [[ -z "${MORPH_CODESIGN_IDENTITY:-}" ]]; then
  printf 'No Developer ID identity supplied; this archive is ad-hoc signed and is not eligible for public distribution.\n' >&2
else
  printf 'No notary profile supplied; the signed archive is not notarized and is not ready for public distribution.\n' >&2
fi
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
printf 'Release archive: %s\n' "$ARCHIVE"
printf 'SHA-256: '
cat "$ARCHIVE.sha256"
if [[ -z "${MORPH_CODESIGN_IDENTITY:-}" || -z "${MORPH_NOTARY_PROFILE:-}" ]]; then
  printf 'Do not publish a Homebrew Cask until Developer ID signing and notarization are complete.\n'
fi
