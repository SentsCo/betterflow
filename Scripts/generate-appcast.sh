#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
version="${BETTERFLOW_VERSION:?BETTERFLOW_VERSION is required}"
tag="${BETTERFLOW_TAG:-v$version}"
private_key="${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
release_dir="$project_dir/dist/release"
archive="$release_dir/Betterflow-$version-macOS.zip"
appcast="$release_dir/appcast.xml"
sparkle_tool="$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/betterflow-appcast.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

if [[ ! -f "$archive" ]]; then
  print -u2 "error: release archive not found at $archive"
  exit 1
fi
if [[ ! -x "$sparkle_tool" ]]; then
  print -u2 "error: Sparkle tools are unavailable; run swift package resolve"
  exit 1
fi

cp "$archive" "$temporary_dir/"
printf '%s' "$private_key" | "$sparkle_tool" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/zachsents/betterflow/releases/download/$tag/" \
  --link "https://github.com/zachsents/betterflow" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$appcast" \
  "$temporary_dir"

print "$appcast"
