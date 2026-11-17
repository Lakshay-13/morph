#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="${MORPH_APP_SOURCE:-$REPO_ROOT/dist/Morph.app}"
APP_DEST="$HOME/Applications/Morph.app"
WORKFLOW_SOURCE="$REPO_ROOT/Resources/QuickActions/Convert with Morph.workflow"
WORKFLOW_DEST="$HOME/Library/Services/Convert with Morph.workflow"

if [[ ! -d "$APP_SOURCE" || ! -f "$APP_SOURCE/Contents/Info.plist" ]]; then
  printf 'Build Morph first or set MORPH_APP_SOURCE to a built Morph.app: %s\n' "$APP_SOURCE" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SOURCE/Contents/Info.plist")" != "com.lakshaychawla.Morph" ]]; then
  printf 'Refusing to install an app with an unexpected bundle identifier.\n' >&2
  exit 1
fi
if [[ ! -d "$WORKFLOW_SOURCE" ]]; then
  printf 'Missing Finder Quick Action bundle: %s\n' "$WORKFLOW_SOURCE" >&2
  exit 1
fi

mkdir -p "$HOME/Applications" "$HOME/Library/Services"
if [[ -e "$APP_DEST" ]]; then
  if [[ ! -f "$APP_DEST/Contents/Info.plist" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DEST/Contents/Info.plist")" != "com.lakshaychawla.Morph" ]]; then
    printf 'Refusing to replace a different application at %s\n' "$APP_DEST" >&2
    exit 1
  fi
fi

if [[ -e "$WORKFLOW_DEST" ]] && ! diff -qr "$WORKFLOW_SOURCE" "$WORKFLOW_DEST" >/dev/null; then
  EXISTING_ACTION_ID="$(/usr/libexec/PlistBuddy -c 'Print :MORPHQuickActionIdentifier' "$WORKFLOW_DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ACTION_ID" != "com.lakshaychawla.Morph.ConvertWithMorph" ]]; then
    printf 'A different Quick Action already exists at %s; leaving it unchanged.\n' "$WORKFLOW_DEST" >&2
    exit 1
  fi
fi

ditto --rsrc --extattr "$APP_SOURCE" "$APP_DEST"
if [[ ! -e "$WORKFLOW_DEST" ]] || ! diff -qr "$WORKFLOW_SOURCE" "$WORKFLOW_DEST" >/dev/null; then
  ditto --rsrc --extattr "$WORKFLOW_SOURCE" "$WORKFLOW_DEST"
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP_DEST"
open "$APP_DEST"
printf 'Installed Morph at %s\n' "$APP_DEST"
printf 'Installed Finder Quick Action at %s\n' "$WORKFLOW_DEST"
