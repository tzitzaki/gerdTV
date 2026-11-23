# Installing gerdTV

Releases: https://github.com/tzitzaki/gerdTV/releases. Install the first copy by hand; after that the app offers updates (desktop and Android install after you confirm; iOS notifies only).

## macOS
Download `gerdTV-macos-<version>.dmg`, open it and drag gerdTV onto Applications (the zip next to it is for the in-app updater). The first open is blocked (self-signed, not notarized): System Settings > Privacy & Security > "Open Anyway", once. Allow Keychain access ("Always Allow") and Local Network (for Cast discovery).

## Android TV (e.g. Nvidia Shield)
Allow unknown sources for a file manager or downloader app (Settings > Device Preferences > Security & restrictions), download `gerdTV-android-<version>.apk` there and install it. The arm64-v8a build runs on 64-bit Android TV devices, including ones with a 32+64-bit userspace. The first in-app update asks once to allow "Install unknown apps" for gerdTV.

## Android phone
Open the APK from the browser's downloads and allow the install.

## iPhone / iPad
Download `gerdTV-ios-unsigned-<version>.ipa` and re-sign and install it with a re-signing service. Always use the same signing certificate: with a different one the stored login and TMDB key can't be read and must be entered again. The app only notifies about updates; repeat this per update.

## Linux (x64)
Unpack `gerdTV-linux-x64-<version>.tar.gz` anywhere and run `gerdTV/gerdtv`. Needs libmpv, GTK 3, libsecret (the login is kept in the desktop keyring) and (for the tray icon) AppIndicator. To update, replace the folder.

## Checking a download
Each release has `latest.json` with every asset's SHA-256 (signed in `latest.json.sig`); `shasum -a 256 <file>` must match.
