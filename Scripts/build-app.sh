#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${MORPH_DIST_DIR:-$REPO_ROOT/dist}"
BUILD_ARCH="${MORPH_BUILD_ARCH:-$(uname -m)}"
APP_VERSION="${MORPH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/Resources/Info.plist")}"
APP_PATH="$DIST_ROOT/Morph.app"
ICON_SOURCE="$REPO_ROOT/morph-logo.png"
SIGN_IDENTITY="${MORPH_CODESIGN_IDENTITY:--}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  printf 'MORPH_VERSION must be a safe semantic version (received %s).\n' "$APP_VERSION" >&2
  exit 2
fi

if [[ -e "$APP_PATH" ]]; then
  printf 'Refusing to overwrite existing app: %s\n' "$APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'Missing app icon source: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi
mkdir -p "$DIST_ROOT"

build_for_arch() {
  local arch="$1"
  local scratch="$REPO_ROOT/.build/release-$arch"
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --product Morph >&2 || return $?
  local bin_path
  bin_path="$(swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --show-bin-path)" || return $?
  printf '%s\n' "$bin_path/Morph"
}

if [[ "$BUILD_ARCH" == "universal" ]]; then
  if ! ARM_BINARY="$(build_for_arch arm64)"; then exit 1; fi
  if ! INTEL_BINARY="$(build_for_arch x86_64)"; then exit 1; fi
  APP_EXECUTABLE="$DIST_ROOT/Morph-universal"
  if [[ -e "$APP_EXECUTABLE" ]]; then
    printf 'Refusing to overwrite existing universal binary: %s\n' "$APP_EXECUTABLE" >&2
    exit 1
  fi
  lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_EXECUTABLE"
elif [[ "$BUILD_ARCH" == "arm64" || "$BUILD_ARCH" == "x86_64" ]]; then
  if ! APP_EXECUTABLE="$(build_for_arch "$BUILD_ARCH")"; then exit 1; fi
else
  printf 'MORPH_BUILD_ARCH must be arm64, x86_64, or universal (received %s).\n' "$BUILD_ARCH" >&2
  exit 2
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if [[ "$BUILD_ARCH" == "universal" ]]; then
  mv "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/Morph"
else
  cp "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/Morph"
fi
cp "$REPO_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PATH/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/morph-logo.png"
ditto "$REPO_ROOT/Resources/QuickActions/Convert with Morph.workflow" "$APP_PATH/Contents/Resources/Convert with Morph.workflow"

ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/morph-iconset.XXXXXX")/Morph.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/Morph.icns"
rm -r "$(dirname "$ICONSET")"

plutil -lint "$APP_PATH/Contents/Info.plist"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_PATH"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
printf 'Built Morph app: %s\n' "$APP_PATH"
printf 'Architecture: %s\n' "$(lipo -archs "$APP_PATH/Contents/MacOS/Morph")"
