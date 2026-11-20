#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${MORPH_DIST_DIR:-$REPO_ROOT/dist}"
BUILD_ARCH="${MORPH_BUILD_ARCH:-$(uname -m)}"
APP_VERSION="${MORPH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/Resources/Info.plist")}"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$REPO_ROOT/Resources/Info.plist")"
APP_PATH="$DIST_ROOT/Morph.app"
ICON_SOURCE="$REPO_ROOT/morph-logo.png"
MENUBAR_ICON_GENERATOR="$REPO_ROOT/Scripts/generate-menubar-icon.swift"
SIGN_IDENTITY="${MORPH_CODESIGN_IDENTITY:--}"
KEYCHAIN_ACCESS_GROUP="${MORPH_KEYCHAIN_ACCESS_GROUP:-}"
APP_PROVISIONING_PROFILE="${MORPH_APP_PROVISIONING_PROFILE:-}"
HELPER_PROVISIONING_PROFILE="${MORPH_HELPER_PROVISIONING_PROFILE:-}"
APP_KEYCHAIN_ENTITLEMENTS=""
HELPER_KEYCHAIN_ENTITLEMENTS=""
PROFILE_PLIST_FILES=()
cleanup_keychain_entitlements() {
  if [[ -n "$APP_KEYCHAIN_ENTITLEMENTS" ]]; then rm -f "$APP_KEYCHAIN_ENTITLEMENTS"; fi
  if [[ -n "$HELPER_KEYCHAIN_ENTITLEMENTS" ]]; then rm -f "$HELPER_KEYCHAIN_ENTITLEMENTS"; fi
  for profile_plist in "${PROFILE_PLIST_FILES[@]:-}"; do
    [[ -z "$profile_plist" ]] || rm -f "$profile_plist"
  done
}
trap cleanup_keychain_entitlements EXIT

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
if [[ -n "$KEYCHAIN_ACCESS_GROUP" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'MORPH_KEYCHAIN_ACCESS_GROUP requires a signed Morph build; refusing to place it in an ad-hoc bundle.\n' >&2
    exit 2
  fi
  if [[ ! "$KEYCHAIN_ACCESS_GROUP" =~ ^[A-Za-z0-9]{10}\.com\.lakshaychawla\.Morph$ ]]; then
    printf 'MORPH_KEYCHAIN_ACCESS_GROUP must use the team-prefixed Morph app identifier.\n' >&2
    exit 2
  fi
  if [[ -z "$APP_PROVISIONING_PROFILE" || -z "$HELPER_PROVISIONING_PROFILE" ]]; then
    printf 'Shared Keychain builds require both MORPH_APP_PROVISIONING_PROFILE and MORPH_HELPER_PROVISIONING_PROFILE.\n' >&2
    exit 2
  fi
  TEAM_ID="${KEYCHAIN_ACCESS_GROUP%%.*}"
  validate_provisioning_profile() {
    local profile_path="$1"
    local bundle_identifier="$2"
    local profile_name="$3"
    if [[ ! -f "$profile_path" ]]; then
      printf '%s provisioning profile does not exist: %s\n' "$profile_name" "$profile_path" >&2
      exit 2
    fi
    local decoded_profile
    decoded_profile="$(mktemp "${TMPDIR:-/tmp}/morph-${profile_name}-profile.XXXXXX")"
    PROFILE_PLIST_FILES+=("$decoded_profile")
    if ! security cms -D -i "$profile_path" -o "$decoded_profile" >/dev/null 2>&1 || ! plutil -lint "$decoded_profile" >/dev/null; then
      printf '%s provisioning profile could not be decoded or validated.\n' "$profile_name" >&2
      exit 2
    fi
    local profile_team
    profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile" 2>/dev/null || true)"
    if [[ "$profile_team" != "$TEAM_ID" ]]; then
      printf '%s provisioning profile team does not match MORPH_KEYCHAIN_ACCESS_GROUP.\n' "$profile_name" >&2
      exit 2
    fi
    local profile_app_id
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded_profile" 2>/dev/null || true)"
    if [[ "$profile_app_id" != "$TEAM_ID.$bundle_identifier" ]]; then
      printf '%s provisioning profile application identifier must exactly match %s (wildcard profiles are not accepted).\n' "$profile_name" "$TEAM_ID.$bundle_identifier" >&2
      exit 2
    fi
    local profile_expiration profile_expiration_epoch now_epoch
    profile_expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$decoded_profile" 2>/dev/null || true)"
    profile_expiration_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S %z' "$profile_expiration" '+%s' 2>/dev/null || true)"
    now_epoch="$(/bin/date '+%s')"
    if [[ ! "$profile_expiration_epoch" =~ ^[0-9]+$ || "$profile_expiration_epoch" -le "$now_epoch" ]]; then
      printf '%s provisioning profile is expired or has an invalid expiration date.\n' "$profile_name" >&2
      exit 2
    fi
    local get_task_allow
    get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$decoded_profile" 2>/dev/null || true)"
    if [[ "$get_task_allow" != "false" ]]; then
      printf '%s provisioning profile enables debugging or has no verifiable get-task-allow entitlement.\n' "$profile_name" >&2
      exit 2
    fi
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices:0' "$decoded_profile" >/dev/null 2>&1; then
      printf '%s provisioning profile is device-scoped and cannot be used for public Mac distribution.\n' "$profile_name" >&2
      exit 2
    fi
    local profile_groups
    profile_groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$decoded_profile" 2>/dev/null || true)"
    if [[ "$profile_groups" != *"$KEYCHAIN_ACCESS_GROUP"* && "$profile_groups" != *"$TEAM_ID.*"* ]]; then
      printf '%s provisioning profile does not authorize Keychain access group %s.\n' "$profile_name" "$KEYCHAIN_ACCESS_GROUP" >&2
      exit 2
    fi
  }
  APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$REPO_ROOT/Resources/Info.plist")"
  HELPER_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$REPO_ROOT/Resources/MorphQuickConvert-Info.plist")"
  validate_provisioning_profile "$APP_PROVISIONING_PROFILE" "$APP_BUNDLE_IDENTIFIER" "app"
  validate_provisioning_profile "$HELPER_PROVISIONING_PROFILE" "$HELPER_BUNDLE_IDENTIFIER" "helper"
  APP_KEYCHAIN_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/morph-app-keychain-entitlements.XXXXXX")"
  HELPER_KEYCHAIN_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/morph-helper-keychain-entitlements.XXXXXX")"
  write_keychain_entitlements() {
    local output_path="$1"
    local bundle_identifier="$2"
    cat > "$output_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>${TEAM_ID}.${bundle_identifier}</string>
  <key>com.apple.developer.team-identifier</key>
  <string>${TEAM_ID}</string>
  <key>keychain-access-groups</key>
  <array><string>${KEYCHAIN_ACCESS_GROUP}</string></array>
</dict>
</plist>
EOF
    plutil -lint "$output_path"
  }
  write_keychain_entitlements "$APP_KEYCHAIN_ENTITLEMENTS" "$APP_BUNDLE_IDENTIFIER"
  write_keychain_entitlements "$HELPER_KEYCHAIN_ENTITLEMENTS" "$HELPER_BUNDLE_IDENTIFIER"
elif [[ -n "$APP_PROVISIONING_PROFILE" || -n "$HELPER_PROVISIONING_PROFILE" ]]; then
  printf 'MORPH_*_PROVISIONING_PROFILE requires MORPH_KEYCHAIN_ACCESS_GROUP.\n' >&2
  exit 2
fi
mkdir -p "$DIST_ROOT"

build_for_arch() {
  local arch="$1"
  local product="$2"
  local scratch="$REPO_ROOT/.build/release-$arch"
  swift build -c release --force-resolved-versions --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --product "$product" >&2 || return $?
  local bin_path
  bin_path="$(swift build -c release --force-resolved-versions --triple "$arch-apple-macosx14.0" --scratch-path "$scratch" --show-bin-path)" || return $?
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
  CURRENT_PROJECT_VERSION="$APP_BUILD" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
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
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP_PATH/Contents/Info.plist"
cp "$REPO_ROOT/Resources/MorphQuickConvert-Info.plist" "$HELPER_APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$HELPER_APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$HELPER_APP_PATH/Contents/Info.plist"
if [[ -n "$KEYCHAIN_ACCESS_GROUP" ]]; then
  cp "$APP_PROVISIONING_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
  cp "$HELPER_PROVISIONING_PROFILE" "$HELPER_APP_PATH/Contents/embedded.provisionprofile"
fi
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/morph-logo.png"
swift "$MENUBAR_ICON_GENERATOR" "$APP_PATH/Contents/Resources/morph-menubar.png"
ditto "$FINDER_SYNC_PRODUCT" "$FINDER_SYNC_APP_PATH"
mkdir -p "$APP_PATH/Contents/Resources/Legal/THIRD_PARTY_LICENSES"
cp "$REPO_ROOT/LICENSE" "$APP_PATH/Contents/Resources/Legal/LICENSE"
cp "$REPO_ROOT/NOTICE" "$APP_PATH/Contents/Resources/Legal/NOTICE"
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
sign_bundle() {
  local bundle="$1"
  shift
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --options runtime --sign - "$@" "$bundle"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@" "$bundle"
  fi
}
sign_bundle "$FINDER_SYNC_APP_PATH" --entitlements "$REPO_ROOT/FinderSync/MorphFinderSync.entitlements"
if [[ -n "$APP_KEYCHAIN_ENTITLEMENTS" ]]; then
  sign_bundle "$HELPER_APP_PATH" --entitlements "$HELPER_KEYCHAIN_ENTITLEMENTS"
  sign_bundle "$APP_PATH" --entitlements "$APP_KEYCHAIN_ENTITLEMENTS"
else
  sign_bundle "$HELPER_APP_PATH"
  sign_bundle "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
if [[ -n "$KEYCHAIN_ACCESS_GROUP" ]]; then
  if ! "$APP_PATH/Contents/MacOS/Morph" --morph-keychain-self-test; then
    printf 'Signed app could not write and read its shared Data Protection Keychain group.\n' >&2
    exit 1
  fi
  if ! "$HELPER_APP_PATH/Contents/MacOS/MorphQuickConvert" --morph-keychain-self-test; then
    printf 'Signed helper could not write and read its shared Data Protection Keychain group.\n' >&2
    exit 1
  fi
  printf 'Shared Data Protection Keychain access: verified by a disposable read/write self-test\n'
fi
printf 'Built Morph app: %s\n' "$APP_PATH"
printf 'Architecture: %s\n' "$(lipo -archs "$APP_PATH/Contents/MacOS/Morph")"
printf 'Built windowless Finder conversion helper: %s\n' "$HELPER_APP_PATH"
printf 'Helper architecture: %s\n' "$(lipo -archs "$HELPER_APP_PATH/Contents/MacOS/MorphQuickConvert")"
if [[ -n "$APP_KEYCHAIN_ENTITLEMENTS" ]]; then
  printf 'Shared Data Protection Keychain access: enabled\n'
else
  printf 'Shared Data Protection Keychain access: unavailable; optional engines and custom output are fail-closed\n'
fi
