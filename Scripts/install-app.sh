#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="${MORPH_APP_SOURCE:-$REPO_ROOT/dist/Morph.app}"
APP_DEST="$HOME/Applications/Morph.app"
WORKFLOW_DEST="$HOME/Library/Services/Convert with Morph.workflow"
QUICK_CONVERT_HELPER="$APP_SOURCE/Contents/Helpers/MorphQuickConvert.app"
FINDER_SYNC_EXTENSION="$APP_SOURCE/Contents/PlugIns/MorphFinderSync.appex"
FINDER_SYNC_ID="com.lakshaychawla.Morph.FinderSync"

if [[ ! -d "$APP_SOURCE" || ! -f "$APP_SOURCE/Contents/Info.plist" ]]; then
  printf 'Build Morph first or set MORPH_APP_SOURCE to a built Morph.app: %s\n' "$APP_SOURCE" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SOURCE/Contents/Info.plist")" != "com.lakshaychawla.Morph" ]]; then
  printf 'Refusing to install an app with an unexpected bundle identifier.\n' >&2
  exit 1
fi
if [[ ! -x "$QUICK_CONVERT_HELPER/Contents/MacOS/MorphQuickConvert" || ! -f "$QUICK_CONVERT_HELPER/Contents/Info.plist" ]]; then
  printf 'The windowless Finder conversion helper is missing from %s\n' "$APP_SOURCE" >&2
  exit 1
fi
if [[ ! -d "$FINDER_SYNC_EXTENSION" || ! -f "$FINDER_SYNC_EXTENSION/Contents/Info.plist" ]]; then
  printf 'The Finder Sync submenu is missing from %s\n' "$APP_SOURCE" >&2
  exit 1
fi

mkdir -p "$HOME/Applications" "$HOME/Library/Services"
if [[ -e "$APP_DEST" ]]; then
  if [[ ! -f "$APP_DEST/Contents/Info.plist" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DEST/Contents/Info.plist")" != "com.lakshaychawla.Morph" ]]; then
    printf 'Refusing to replace a different application at %s\n' "$APP_DEST" >&2
    exit 1
  fi
  EMBEDDED_WORKFLOW="$APP_DEST/Contents/Resources/Convert with Morph.workflow"
  if [[ -d "$EMBEDDED_WORKFLOW" ]]; then
    EMBEDDED_ACTION_ID="$(/usr/libexec/PlistBuddy -c 'Print :MORPHQuickActionIdentifier' "$EMBEDDED_WORKFLOW/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EMBEDDED_ACTION_ID" != "com.lakshaychawla.Morph.ConvertWithMorph" ]]; then
      printf 'Refusing to remove an unrecognized workflow from %s\n' "$EMBEDDED_WORKFLOW" >&2
      exit 1
    fi
    rm -rf "$EMBEDDED_WORKFLOW"
  fi
fi

if [[ -e "$WORKFLOW_DEST" ]]; then
  EXISTING_ACTION_ID="$(/usr/libexec/PlistBuddy -c 'Print :MORPHQuickActionIdentifier' "$WORKFLOW_DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ACTION_ID" == "com.lakshaychawla.Morph.ConvertWithMorph" ]]; then
    rm -rf "$WORKFLOW_DEST"
  else
    printf 'A different Quick Action exists at %s; leaving it unchanged.\n' "$WORKFLOW_DEST" >&2
  fi
fi

ditto --rsrc --extattr "$APP_SOURCE" "$APP_DEST"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP_DEST"
"$LSREGISTER" -f "$APP_DEST/Contents/Helpers/MorphQuickConvert.app"
pluginkit -r "$APP_DEST/Contents/PlugIns/MorphFinderSync.appex" >/dev/null 2>&1 || true
pluginkit -a "$APP_DEST/Contents/PlugIns/MorphFinderSync.appex"
pluginkit -e use -i "$FINDER_SYNC_ID"
printf 'Installed Morph at %s\n' "$APP_DEST"
printf 'Registered Finder conversion submenu: %s\n' "$FINDER_SYNC_ID"
