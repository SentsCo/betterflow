#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

swift build -c release --product Betterflow
"$project_dir/Scripts/prepare-mlx.sh" release
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$project_dir/dist/Betterflow.app"
contents_dir="$app_dir/Contents"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
install -m 755 "$bin_dir/Betterflow" "$contents_dir/MacOS/Betterflow"
install -m 644 "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
install -m 644 "$project_dir/Resources/Betterflow.icns" "$contents_dir/Resources/Betterflow.icns"

resource_bundles=(
  Betterflow_BetterflowEngine.bundle
  FluidAudio_FluidAudio.bundle
  swift-crypto_Crypto.bundle
  swift-transformers_Hub.bundle
)
for bundle_name in "${resource_bundles[@]}"; do
  source_bundle="$bin_dir/$bundle_name"
  if [[ -d "$source_bundle" ]]; then
    ditto "$source_bundle" "$contents_dir/Resources/$bundle_name"
  fi
done

mlx_bundle="$contents_dir/Resources/mlx-swift_Cmlx.bundle"
mkdir -p "$mlx_bundle"
install -m 644 "$bin_dir/Resources/default.metallib" "$mlx_bundle/default.metallib"

signing_identity="${BETTERFLOW_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning \
    | awk '/Apple Development:/ { print $2; exit }')
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  print -u2 "warning: no Apple Development identity found; permission grants may not survive rebuilds"
fi

codesign \
  --force \
  --deep \
  --sign "$signing_identity" \
  --entitlements "$project_dir/Support/Betterflow.entitlements" \
  "$app_dir"

echo "$app_dir"
