#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
version="${BETTERFLOW_VERSION:?BETTERFLOW_VERSION is required}"
build_number="${BETTERFLOW_BUILD:?BETTERFLOW_BUILD is required}"
: "${BETTERFLOW_SIGNING_IDENTITY:?BETTERFLOW_SIGNING_IDENTITY is required}"
release_dir="$project_dir/dist/release"
app_dir="$project_dir/dist/Betterflow.app"
artifact_base="Betterflow-$version-macOS"
zip_path="$release_dir/$artifact_base.zip"
dmg_path="$release_dir/$artifact_base.dmg"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/betterflow-release.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  notary_arguments=(--keychain-profile "$NOTARYTOOL_PROFILE")
else
  : "${APP_STORE_CONNECT_API_KEY_PATH:?APP_STORE_CONNECT_API_KEY_PATH is required}"
  : "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
  notary_arguments=(
    --key "$APP_STORE_CONNECT_API_KEY_PATH"
    --key-id "$APP_STORE_CONNECT_KEY_ID"
    --issuer "$APP_STORE_CONNECT_ISSUER_ID"
  )
fi

rm -rf "$release_dir"
mkdir -p "$release_dir"

BETTERFLOW_DISTRIBUTION=1 \
BETTERFLOW_VERSION="$version" \
BETTERFLOW_BUILD="$build_number" \
  "$project_dir/Scripts/build-app.sh"

notarization_zip="$temporary_dir/$artifact_base-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$notarization_zip"
xcrun notarytool submit "$notarization_zip" "${notary_arguments[@]}" --wait
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
spctl --assess --type execute --verbose=2 "$app_dir"

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"

dmg_staging="$temporary_dir/dmg"
mkdir -p "$dmg_staging"
ditto "$app_dir" "$dmg_staging/Betterflow.app"
ln -s /Applications "$dmg_staging/Applications"
hdiutil create \
  -volname Betterflow \
  -srcfolder "$dmg_staging" \
  -format UDZO \
  -ov \
  "$dmg_path"
codesign --force --sign "$BETTERFLOW_SIGNING_IDENTITY" --timestamp "$dmg_path"
xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

(
  cd "$release_dir"
  shasum -a 256 "$artifact_base.zip" "$artifact_base.dmg" > SHA256SUMS.txt
)
print "$release_dir"
