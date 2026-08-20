# Releasing Betterflow

Install the Blacksmith GitHub App, create a GitHub `release` environment, and add these secrets to it:

- `DEVELOPER_ID_CERTIFICATE_BASE64`: exported Developer ID Application `.p12`, base64 encoded
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: password used when exporting the `.p12`
- `BUILD_KEYCHAIN_PASSWORD`: a random password for the temporary CI keychain
- `APP_STORE_CONNECT_API_KEY_BASE64`: App Store Connect API `.p8`, base64 encoded
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`: the base64 private key exported by Sparkle's `generate_keys`

The Sparkle public key is already embedded in `Support/Info.plist`. Its private key is stored locally in the login Keychain under the account `com.zachsents.betterflow` and must never be committed.

To export it directly into the GitHub secret without leaving a copy in the repository:

```sh
temporary_key=$(mktemp)
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.zachsents.betterflow -x "$temporary_key"
gh secret set SPARKLE_PRIVATE_KEY --env release < "$temporary_key"
rm "$temporary_key"
```

Create a release from a clean commit on `main`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow publishes a notarized DMG for installation, a notarized ZIP for Sparkle, checksums, and `appcast.xml`. The feed URL uses GitHub's `releases/latest` redirect, so no separate update server is needed.
