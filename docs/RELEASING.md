# Releasing

## Versions
`0.YYMMDD.<PR#>`: the date of the wrap-up and the number of the PR that carries it (the session's PR). In `Cargo.toml` (workspace) and `app/pubspec.yaml` as `0.YYMMDD.<PR#>+<PR#>`, so Android's versionCode and iOS's build number always grow. The major stays 0 until the owner changes it.

## Flow
1. The session PR's last commit sets the version and rewrites `docs/HANDOVER.md`; the PR merges like any other (CI runs only the repo rules for a wrap-up on its own: `scripts/ci-scope.sh`).
2. Tag the merge commit `v0.YYMMDD.<PR#>` and push the tag. `.github/workflows/release.yml` runs.
3. `gh run watch`, then `just verify-release <tag>`: downloads the release, checks every asset's size and SHA-256 and the manifest signature.

## What release.yml builds
- `macos-latest`: `gerdTV-macos-<version>.zip` (the app signed with the stable self-signed certificate, packed with `ditto -c -k --keepParent`; the updater's file in `latest.json`), `gerdTV-macos-<version>.dmg` (the same app with an Applications link for the first install, `scripts/macos-dmg.sh`; not in `latest.json`, `just verify-release` checks it is there) and `gerdTV-ios-unsigned-<version>.ipa` (`flutter build ios --release --no-codesign`, `Payload/Runner.app` zipped, for a re-signing service).
- `ubuntu-latest`: `gerdTV-android-<version>.apk` (arm64-v8a, release keystore) and `gerdTV-linux-x64-<version>.tar.gz`.
- Last job: `latest.json` (version, notes, per platform: asset, size, SHA-256, minimum OS) signed with the ed25519 update key into `latest.json.sig` (`gerdtv-release`), then `gh release create` with every asset. Notes: the merged PR titles since the previous published release, each with its commit subjects when it has several (without the version commit; `scripts/release-notes.sh`) (a tag whose release run failed has no release and is skipped) plus install hints linking `docs/INSTALL.md`. Any failed platform job means no release (no half releases). Tags with a `-` (e.g. a test tag) are published as pre-releases.

## Why a stable self-signed certificate on macOS
The updater accepts only a build that meets the installed app's code signing requirement (`app/lib/platform/mac_install.dart`); an ad-hoc signature changes with every build, so no update would pass.

The certificate is not enough for the Keychain: macOS also checks an item's partition list, where an app without an Apple-issued certificate counts as the hash of that exact build, so every update would ask for the keychain password. So the app stores its secrets through `/usr/bin/security`, whose partition doesn't change with our builds (`app/lib/platform/mac_keychain.dart`). A Developer ID certificate would make the Keychain API usable (partition = team ID) and allow notarization; the updater would then have to accept the new certificate from a build signed with the old one.

## Secrets (GitHub environment `release`, usable only by `v*` tags)
| Secret | What |
|---|---|
| `GERDTV_UPDATE_SIGNING_KEY` | ed25519 update key seed, hex (`gerdtv-release keygen`); its public half is `keys/update-public-key.hex` |
| `ANDROID_KEYSTORE_BASE64` | the release keystore, base64 |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS` | keystore and key passwords, key alias |
| `MACOS_CERT_P12_BASE64` | the code-signing certificate + key (.p12, legacy PBE so `security import` accepts it), base64 |
| `MACOS_CERT_PASSWORD` | the .p12 password |

Repository variables (not secrets: public OAuth client ids; no secret ever ships in the app, since anything inside a published app can be extracted): `GERDTV_PREMIUMIZE_CLIENT_ID` and `GERDTV_SIMKL_CLIENT_ID`, gerdTV's registrations at premiumize.me/registerclient and simkl.com/settings/developer, passed to every build as `--dart-define` (`GERDTV_DEFINES` in `release.yml`); empty, the code login of that service is hidden. Trakt needs a client secret, so each user links their own Trakt app instead (Settings → Account → Trakt). Set with `gh variable set <NAME>`.

Set with `gh secret set <NAME> --env release` reading the value from stdin; values are never printed. Losing the Android keystore means uninstalling on every Android device before a new build installs; losing the update key means installed apps can't verify updates. Keep both in a password manager.

## The update key
`cargo run -p gerdtv-release -- keygen <private-key-out> keys/update-public-key.hex` refuses to overwrite an existing key. The app trusts only the committed public key; changing it is a breaking release (older apps reject new manifests).
