#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${MORPH_DIST_DIR:-$REPO_ROOT/dist}"
BUILD_ARCH="${MORPH_BUILD_ARCH:-$(uname -m)}"
APP_VERSION="${MORPH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/Resources/Info.plist")}"
APP_PATH="$DIST_ROOT/Morph.app"
ICON_SOURCE="$REPO_ROOT/morph-logo.png"
MENUBAR_ICON_GENERATOR="$REPO_ROOT/Scripts/generate-menubar-icon.swift"
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
if [[ ! -f "$MENUBAR_ICON_GENERATOR" ]]; then
  printf 'Missing menu-bar icon generator: %s\n' "$MENUBAR_ICON_GENERATOR" >&2
  exit 1
fi
mkdir -p "$DIST_ROOT"

build_for_arch() {
  local arch="$1"
  local product="$2"
  local scratch="$REPO_ROOT/.build/release-$arch"
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --product "$product" >&2 || return $?
  local bin_path
  bin_path="$(swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --show-bin-path)" || return $?
  printf '%s\n' "$bin_path/$product"
}

if [[ "$BUILD_ARCH" == "universal" ]]; then
  if ! ARM_BINARY="$(build_for_arch arm64 Morph)"; then exit 1; fi
  if ! INTEL_BINARY="$(build_for_arch x86_64 Morph)"; then exit 1; fi
  if ! ARM_HELPER_BINARY="$(build_for_arch arm64 MorphQuickConvert)"; then exit 1; fi
  if ! INTEL_HELPER_BINARY="$(build_for_arch x86_64 MorphQuickConvert)"; then exit 1; fi
  APP_EXECUTABLE="$DIST_ROOT/Morph-universal"
  HELPER_EXECUTABLE="$DIST_ROOT/MorphQuickConvert-universal"
  if [[ -e "$APP_EXECUTABLE" ]]; then
    printf 'Refusing to overwrite existing universal binary: %s\n' "$APP_EXECUTABLE" >&2
    exit 1
  fi
  if [[ -e "$HELPER_EXECUTABLE" ]]; then
    printf 'Refusing to overwrite existing universal helper binary: %s\n' "$HELPER_EXECUTABLE" >&2
    exit 1
  fi
  lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_EXECUTABLE"
  lipo -create "$ARM_HELPER_BINARY" "$INTEL_HELPER_BINARY" -output "$HELPER_EXECUTABLE"
elif [[ "$BUILD_ARCH" == "arm64" || "$BUILD_ARCH" == "x86_64" ]]; then
  if ! APP_EXECUTABLE="$(build_for_arch "$BUILD_ARCH" Morph)"; then exit 1; fi
  if ! HELPER_EXECUTABLE="$(build_for_arch "$BUILD_ARCH" MorphQuickConvert)"; then exit 1; fi
else
  printf 'MORPH_BUILD_ARCH must be arm64, x86_64, or universal (received %s).\n' "$BUILD_ARCH" >&2
  exit 2
fi

SYNC_DERIVED_DATA="$REPO_ROOT/.build/finder-sync-${BUILD_ARCH}"
EXTENSION_ARCHS="$BUILD_ARCH"
if [[ "$BUILD_ARCH" == "universal" ]]; then
  EXTENSION_ARCHS="arm64 x86_64"
fi
xcodebuild \
  -quiet \
  -project "$REPO_ROOT/FinderSync/MorphFinderSync.xcodeproj" \
  -scheme MorphFinderSync \
  -configuration Release \
  -derivedDataPath "$SYNC_DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  ARCHS="$EXTENSION_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$APP_VERSION" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build
FINDER_SYNC_PRODUCT="$SYNC_DERIVED_DATA/Build/Products/Release/MorphFinderSync.appex"
if [[ ! -d "$FINDER_SYNC_PRODUCT" ]]; then
  printf 'Finder Sync extension build product is missing: %s\n' "$FINDER_SYNC_PRODUCT" >&2
  exit 1
fi

HELPER_APP_PATH="$APP_PATH/Contents/Helpers/MorphQuickConvert.app"
FINDER_SYNC_APP_PATH="$APP_PATH/Contents/PlugIns/MorphFinderSync.appex"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$HELPER_APP_PATH/Contents/MacOS" "$APP_PATH/Contents/PlugIns"
if [[ "$BUILD_ARCH" == "universal" ]]; then
  mv "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/Morph"
else
  cp "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/Morph"
fi
if [[ "$BUILD_ARCH" == "universal" ]]; then
  mv "$HELPER_EXECUTABLE" "$HELPER_APP_PATH/Contents/MacOS/MorphQuickConvert"
else
  cp "$HELPER_EXECUTABLE" "$HELPER_APP_PATH/Contents/MacOS/MorphQuickConvert"
fi
cp "$REPO_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PATH/Contents/Info.plist"
cp "$REPO_ROOT/Resources/MorphQuickConvert-Info.plist" "$HELPER_APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$HELPER_APP_PATH/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/morph-logo.png"
swift "$MENUBAR_ICON_GENERATOR" "$APP_PATH/Contents/Resources/morph-menubar.png"
ditto "$FINDER_SYNC_PRODUCT" "$FINDER_SYNC_APP_PATH"
mkdir -p "$APP_PATH/Contents/Resources/Legal/THIRD_PARTY_LICENSES"
cp "$REPO_ROOT/LICENSE" "$APP_PATH/Contents/Resources/Legal/LICENSE"
cp "$REPO_ROOT/docs/THIRD_PARTY.md" "$APP_PATH/Contents/Resources/Legal/THIRD_PARTY.md"
ditto "$REPO_ROOT/THIRD_PARTY_LICENSES" "$APP_PATH/Contents/Resources/Legal/THIRD_PARTY_LICENSES"

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
plutil -lint "$HELPER_APP_PATH/Contents/Info.plist"
plutil -lint "$FINDER_SYNC_APP_PATH/Contents/Info.plist"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$HELPER_APP_PATH"
  codesign --force --sign - "$APP_PATH"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$HELPER_APP_PATH"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
printf 'Built Morph app: %s\n' "$APP_PATH"
printf 'Architecture: %s\n' "$(lipo -archs "$APP_PATH/Contents/MacOS/Morph")"
printf 'Built windowless Finder conversion helper: %s\n' "$HELPER_APP_PATH"
printf 'Helper architecture: %s\n' "$(lipo -archs "$HELPER_APP_PATH/Contents/MacOS/MorphQuickConvert")"
