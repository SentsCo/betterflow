#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

configuration="${BETTERFLOW_CONFIGURATION:-release}"
version="${BETTERFLOW_VERSION:-0.1.0}"
build_number="${BETTERFLOW_BUILD:-1}"
distribution="${BETTERFLOW_DISTRIBUTION:-0}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "error: BETTERFLOW_VERSION must be a semantic version"
  exit 1
fi
if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "error: BETTERFLOW_BUILD must be a positive integer"
  exit 1
fi

swift build -c "$configuration" --product Betterflow
"$project_dir/Scripts/prepare-mlx.sh" "$configuration"
bin_dir=$(swift build -c "$configuration" --show-bin-path)
app_dir="$project_dir/dist/Betterflow.app"
contents_dir="$app_dir/Contents"
frameworks_dir="$contents_dir/Frameworks"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$frameworks_dir"
install -m 755 "$bin_dir/Betterflow" "$contents_dir/MacOS/Betterflow"
install_name_tool -add_rpath @executable_path/../Frameworks \
  "$contents_dir/MacOS/Betterflow"

if uv_path=$(command -v uv); then
  install -m 755 "$uv_path" "$contents_dir/MacOS/uv"
elif [[ "$distribution" == "1" ]]; then
  print -u2 "error: uv must be installed for a distribution build"
  exit 1
else
  print -u2 "warning: uv is not installed; Qwen transcription will be unavailable"
fi

install -m 644 "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_dir/Info.plist"
install -m 644 "$project_dir/Resources/Betterflow.icns" "$contents_dir/Resources/Betterflow.icns"
install -m 644 "$project_dir/LICENSE" "$contents_dir/Resources/LICENSE"
install -m 644 "$project_dir/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"
licenses_dir="$contents_dir/Resources/ThirdPartyLicenses"
mkdir -p "$licenses_dir"
for dependency_dir in "$project_dir"/.build/checkouts/*; do
  dependency_name="${dependency_dir:t}"
  for license_file in "$dependency_dir"/LICENSE*(N) "$dependency_dir"/COPYING*(N); do
    install -m 644 "$license_file" "$licenses_dir/$dependency_name-${license_file:t}"
  done
done
install -m 644 "$project_dir/ThirdPartyLicenses/Moonshine.txt" \
  "$licenses_dir/Moonshine.txt"

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

sparkle_framework_source="$bin_dir/Sparkle.framework"
if [[ ! -d "$sparkle_framework_source" ]]; then
  print -u2 "error: Sparkle.framework was not resolved by Swift Package Manager"
  exit 1
fi
ditto "$sparkle_framework_source" "$frameworks_dir/Sparkle.framework"

signing_identity="${BETTERFLOW_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && "$distribution" == "1" ]]; then
  signing_identity=$(security find-identity -v -p codesigning \
    | awk '/Developer ID Application:/ { print $2; exit }')
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning \
    | awk '/Apple Development:/ { print $2; exit }')
fi
if [[ -z "$signing_identity" ]]; then
  if [[ "$distribution" == "1" ]]; then
    print -u2 "error: a Developer ID Application identity is required"
    exit 1
  fi
  signing_identity="-"
  print -u2 "warning: no Apple Development identity found; permission grants may not survive rebuilds"
fi
if [[ "$distribution" == "1" && "$signing_identity" != *"Developer ID Application"* ]]; then
  identity_name=$(security find-identity -v -p codesigning \
    | awk -v identity="$signing_identity" 'index($0, identity) { print; exit }')
  if [[ "$identity_name" != *"Developer ID Application"* ]]; then
    print -u2 "error: BETTERFLOW_SIGNING_IDENTITY must select a Developer ID Application certificate"
    exit 1
  fi
fi

signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  signing_options+=(--options runtime --timestamp=none)
  if [[ "$distribution" == "1" ]]; then
    signing_options[-1]=--timestamp
  fi
fi

sparkle_version="$frameworks_dir/Sparkle.framework/Versions/B"
codesign "${signing_options[@]}" "$sparkle_version/XPCServices/Installer.xpc"
codesign "${signing_options[@]}" --preserve-metadata=entitlements \
  "$sparkle_version/XPCServices/Downloader.xpc"
codesign "${signing_options[@]}" "$sparkle_version/Autoupdate"
codesign "${signing_options[@]}" "$sparkle_version/Updater.app"
codesign "${signing_options[@]}" "$frameworks_dir/Sparkle.framework"

if [[ -f "$contents_dir/MacOS/uv" ]]; then
  codesign "${signing_options[@]}" "$contents_dir/MacOS/uv"
fi
codesign \
  "${signing_options[@]}" \
  --entitlements "$project_dir/Support/Betterflow.entitlements" \
  "$app_dir"

codesign --verify --deep --strict --verbose=2 "$app_dir"
print "$app_dir"
