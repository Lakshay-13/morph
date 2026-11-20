#!/bin/bash
set -euo pipefail

# Keep the real-engine CI fixtures aligned with Morph's executable security
# floors. Update these minimums alongside EngineSecurityPolicy and its
# regression cases. Install current Homebrew formulae instead of extracting
# historical formula files that become incompatible with current Homebrew DSL.
readonly engine_minimums=(
  "ffmpeg:9.0.2"
  "ghostscript:10.08.0"
  "imagemagick:7.1.2-36"
  "pandoc:3.14"
)

engines=("${engine_minimums[@]}")
if [[ "$(uname -m)" == "arm64" ]]; then
  engines+=("sevenzip:26.06")
fi

formulas=()
for entry in "${engines[@]}"; do
  formula="${entry%%:*}"
  formulas+=("$formula")
done

# GitHub's macOS images can ship with stale Homebrew metadata and preinstalled
# engine versions. Refresh formula metadata first, then upgrade installed
# formulae or install missing ones so the checks use the versions Morph trusts.
brew update

for formula in "${formulas[@]}"; do
  if brew list --versions "$formula" >/dev/null 2>&1; then
    brew upgrade --formula "$formula"
  else
    brew install --formula "$formula"
  fi
done

version_is_at_least() {
  awk -v actual="$1" -v minimum="$2" '
    BEGIN {
      gsub(/[-+_]/, ".", actual)
      gsub(/[-+_]/, ".", minimum)
      actual_count = split(actual, actual_parts, ".")
      minimum_count = split(minimum, minimum_parts, ".")
      part_count = actual_count > minimum_count ? actual_count : minimum_count

      for (i = 1; i <= part_count; i++) {
        actual_part = actual_parts[i] + 0
        minimum_part = minimum_parts[i] + 0
        if (actual_part > minimum_part) exit 0
        if (actual_part < minimum_part) exit 1
      }
      exit 0
    }
  '
}

for entry in "${engines[@]}"; do
  formula="${entry%%:*}"
  minimum_version="${entry#*:}"
  installed_version="$(brew list --versions "$formula" | awk 'NR == 1 { print $2 }')"
  if [[ ! "$installed_version" =~ ^[0-9]+([._+-][0-9]+)*$ ]] \
      || ! version_is_at_least "$installed_version" "$minimum_version"; then
    printf '%s must be at least %s for CI checks; found %s\n' \
      "$formula" "$minimum_version" "${installed_version:-missing}" >&2
    exit 1
  fi
done
