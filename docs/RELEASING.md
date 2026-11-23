# Releasing

## Versions
`0.YYMMDD.<PR#>`: the date of the wrap-up and the wrap-up PR's number. In `Cargo.toml` (workspace) and `app/pubspec.yaml` as `0.YYMMDD.<PR#>+<PR#>`, so Android's versionCode and iOS's build number always grow. The major stays 0 until the owner changes it.

## Flow
1. The wrap-up PR sets the version and rewrites `docs/HANDOVER.md`; it merges like any PR.
2. Tag the merge commit `v0.YYMMDD.<PR#>` and push the tag. `.github/workflows/release.yml` runs.
3. `gh run watch`, then `just verify-release <tag>`: downloads the release, checks every asset's size and SHA-256 and the manifest signature.

## What release.yml builds
- `macos-latest`: `gerdTV-macos-<version>.zip` (the app signed with the stable self-signed certificate, packed with `ditto -c -k --keepParent`; the updater's file in `latest.json`), `gerdTV-macos-<version>.dmg` (the same app with an Applications link for the first install, `scripts/macos-dmg.sh`; not in `latest.json`, `just verify-release` checks it is there) and `gerdTV-ios-unsigned-<version>.ipa` (`flutter build ios --release --no-codesign`, `Payload/Runner.app` zipped, for a re-signing service).
- `ubuntu-latest`: `gerdTV-android-<version>.apk` (arm64-v8a, release keystore) and `gerdTV-linux-x64-<version>.tar.gz`.
- Last job: `latest.json` (version, notes, per platform: asset, size, SHA-256, minimum OS) signed with the ed25519 update key into `latest.json.sig` (`gerdtv-release`), then `gh release create` with every asset. Notes: the merged PR titles since the previous published release (a tag whose release run failed has no release and is skipped) plus install hints linking `docs/INSTALL.md`. Any failed platform job means no release (no half releases). Tags with a `-` (e.g. a test tag) are published as pre-releases.

## Why a stable self-signed certificate on macOS
An ad-hoc signature changes with every build, so the Keychain would ask again (or refuse) for stored credentials after each update. A stable certificate keeps the Keychain's access rules valid across updates.

## Secrets (GitHub environment `release`, usable only by `v*` tags)
| Secret | What |
|---|---|
| `GERDTV_UPDATE_SIGNING_KEY` | ed25519 update key seed, hex (`gerdtv-release keygen`); its public half is `keys/update-public-key.hex` |
| `ANDROID_KEYSTORE_BASE64` | the release keystore, base64 |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` | keystore and key passwords, key alias |
| `MACOS_CERT_P12_BASE64` | the code-signing certificate + key (.p12, legacy PBE so `security import` accepts it), base64 |
| `MACOS_CERT_PASSWORD` | the .p12 password |

Set with `gh secret set <NAME> --env release` reading the value from stdin; values are never printed. Losing the Android keystore means uninstalling on every Android device before a new build installs; losing the update key means installed apps can't verify updates. Keep both in a password manager.

## The update key
`cargo run -p gerdtv-release -- keygen <private-key-out> keys/update-public-key.hex` refuses to overwrite an existing key. The app trusts only the committed public key; changing it is a breaking release (older apps reject new manifests).
