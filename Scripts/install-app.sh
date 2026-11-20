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

  for morph_process_name in Morph MorphQuickConvert; do
    while IFS= read -r morph_pid; do
      [[ -n "$morph_pid" ]] || continue
      morph_process_command="$(ps -p "$morph_pid" -o command= 2>/dev/null || true)"
      case "$morph_process_command" in
        "$APP_DEST/Contents/MacOS/Morph"*|"$APP_DEST/Contents/Helpers/MorphQuickConvert.app/Contents/MacOS/MorphQuickConvert"*)
          printf 'Quit Morph, including its menu-bar conversion helper, before updating the running app at %s\n' "$APP_DEST" >&2
          exit 1
          ;;
      esac
    done < <(pgrep -x "$morph_process_name" || true)
  done
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BACKUP_APP="$HOME/Applications/.Morph-backup-$$.app"
HAD_EXISTING_APP=0
if [[ -e "$BACKUP_APP" ]]; then
  printf 'A prior install backup exists at %s; refusing to overwrite it.\n' "$BACKUP_APP" >&2
  exit 1
fi
STAGING_ROOT="$(mktemp -d "$HOME/Applications/.Morph-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Morph.app"
cleanup() {
  if [[ -d "$BACKUP_APP" && ! -e "$APP_DEST" ]]; then
    mv "$BACKUP_APP" "$APP_DEST"
  fi
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

ditto --rsrc --extattr "$APP_SOURCE" "$STAGED_APP"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")" != "com.lakshaychawla.Morph" ]]; then
  printf 'The staged bundle has an unexpected application identifier.\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$APP_DEST" ]]; then
  mv "$APP_DEST" "$BACKUP_APP"
  HAD_EXISTING_APP=1
fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
  if [[ "$HAD_EXISTING_APP" == "1" ]]; then mv "$BACKUP_APP" "$APP_DEST"; fi
  printf 'Morph could not replace the existing application bundle.\n' >&2
  exit 1
fi

if ! "$LSREGISTER" -f "$APP_DEST" ||
   ! "$LSREGISTER" -f "$APP_DEST/Contents/Helpers/MorphQuickConvert.app" ||
   ! pluginkit -a "$APP_DEST/Contents/PlugIns/MorphFinderSync.appex" ||
   ! pluginkit -e use -i "$FINDER_SYNC_ID"; then
  rm -rf "$APP_DEST"
  if [[ "$HAD_EXISTING_APP" == "1" ]]; then mv "$BACKUP_APP" "$APP_DEST"; fi
  printf 'Morph registration failed; the previous application bundle was restored.\n' >&2
  exit 1
fi

if [[ "$HAD_EXISTING_APP" == "1" ]]; then rm -rf "$BACKUP_APP"; fi
if [[ -e "$WORKFLOW_DEST" ]]; then
  EXISTING_ACTION_ID="$(/usr/libexec/PlistBuddy -c 'Print :MORPHQuickActionIdentifier' "$WORKFLOW_DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ACTION_ID" == "com.lakshaychawla.Morph.ConvertWithMorph" ]]; then
    rm -rf "$WORKFLOW_DEST"
  else
    printf 'A different Quick Action exists at %s; leaving it unchanged.\n' "$WORKFLOW_DEST" >&2
  fi
fi
printf 'Installed Morph at %s\n' "$APP_DEST"
printf 'Registered Finder conversion submenu: %s\n' "$FINDER_SYNC_ID"
