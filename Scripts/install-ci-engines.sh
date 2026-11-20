#!/bin/bash
set -euo pipefail

# Keep the real-engine CI fixtures aligned with Morph's executable security
# floors. Update this list alongside EngineSecurityPolicy and its regression
# cases; brew extract preserves the selected Homebrew formula versions instead
# of following a moving latest release.
readonly engine_tap="codex/morph-ci-engine-pins"
readonly engines=(
  "ffmpeg:9.0.2"
  "ghostscript:10.08.0"
  "imagemagick:7.1.2-36"
  "pandoc:3.14"
  "sevenzip:26.06"
)

brew tap --force homebrew/core
core_repository="$(brew --repository homebrew/core)"
if [[ "$(git -C "$core_repository" rev-parse --is-shallow-repository)" == true ]]; then
  git -C "$core_repository" fetch --unshallow
fi

brew tap-new --no-git "$engine_tap"

install_specs=()
for entry in "${engines[@]}"; do
  formula="${entry%%:*}"
  version="${entry#*:}"
  brew extract --version="$version" "$formula" "$engine_tap"
  install_specs+=("$engine_tap/$formula@$version")
done

brew install "${install_specs[@]}"

for entry in "${engines[@]}"; do
  formula="${entry%%:*}"
  version="${entry#*:}"
  installed_version="$(brew list --versions "$engine_tap/$formula@$version" | awk 'NR == 1 { print $2 }')"
  if [[ "$installed_version" != "$version" ]]; then
    printf 'Expected %s %s, found %s\n' "$formula" "$version" "${installed_version:-missing}" >&2
    exit 1
  fi
done
