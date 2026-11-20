#!/bin/bash
set -euo pipefail

readonly cask_tap="codex/morph-ci-libreoffice"
readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_root="$(cd "$script_directory/.." && pwd)"

brew tap-new --no-git "$cask_tap"
cask_tap_path="$(brew --repository "$cask_tap")"
mkdir -p "$cask_tap_path/Casks"
cp "$repository_root/.github/ci-casks/libreoffice.rb" "$cask_tap_path/Casks/libreoffice.rb"
brew install --cask "$cask_tap/libreoffice"

installed_version="$(brew list --cask --versions "$cask_tap/libreoffice" | awk 'NR == 1 { print $2 }')"
if [[ "$installed_version" != "26.8.3" ]]; then
  printf 'Expected LibreOffice 26.8.3, found %s\n' "${installed_version:-missing}" >&2
  exit 1
fi
