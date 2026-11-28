# Installing gerdTV

Releases: https://github.com/tzitzaki/gerdTV/releases. Install the first copy by hand; after that the app offers updates (desktop and Android install after you confirm; iOS notifies only).

## macOS
Needs macOS 26 on a Mac with Apple Silicon. Download `gerdTV-macos-<version>.dmg`, open it and drag gerdTV onto Applications (the zip next to it is for the in-app updater). The first open is blocked (self-signed, not notarized): System Settings > Privacy & Security > "Open Anyway", once. Updating from a version that still asks for Keychain access after each update: allow it one last time per stored login ("Always Allow"). Allow Local Network (for Cast discovery).

## Android TV (e.g. Nvidia Shield)
Allow unknown sources for a file manager or downloader app (Settings > Device Preferences > Security & restrictions), download `gerdTV-android-<version>.apk` there and install it. The arm64-v8a build runs on 64-bit Android TV devices, including ones with a 32+64-bit userspace. The first in-app update asks once to allow "Install unknown apps" for gerdTV.

## Android phone
Open the APK from the browser's downloads and allow the install.

## iPhone / iPad
Needs iOS/iPadOS 26. Download `gerdTV-ios-unsigned-<version>.ipa` and re-sign and install it with a re-signing service. Always use the same signing certificate: with a different one the stored login and TMDB key can't be read and must be entered again. The app only notifies about updates; repeat this per update.

## Linux (x64)
Unpack `gerdTV-linux-x64-<version>.tar.gz` anywhere and run `gerdTV/gerdtv`. Needs libmpv, GTK 3, libsecret (the login is kept in the desktop keyring) and (for the tray icon) AppIndicator. To update, replace the folder.

## Web player host (a Linux machine of yours)
`gerdTV-host-linux-x64-<version>` is one binary: it keeps one profile in sync and serves the web player to browsers. It needs two public names on a tunnel or reverse proxy of yours, both pointed at it: the front door over HTTPS (login links only) and the player over plain HTTP (so the browser may play the provider's http:// streams itself; the video never passes the host or the tunnel). Run it as its own user with a state folder only that user can read:
- Pair it once (stop the service first): `gerdtv-host pair --dir /var/lib/gerdtv --front https://<front name>` (the app learns the web address from it), then in the gerdTV app Settings → Devices → Devices & sync: pick "gerdTV host" and type the code it prints. It gets the app's open provider, keys and user data.
- Serve: `gerdtv-host serve --dir /var/lib/gerdtv --front https://<front name> --player http://<player name> --listen 127.0.0.1:8790 --proxy <tunnel's address>` (paired apps sync with it on TCP 8791, `--pair-port`; allow that and mDNS, UDP 5353, from the LAN only) (a systemd unit with `Restart=always` and `RestartSec=5`, so a crash loop never hits systemd's start limit; logs in the journal, which names the running version at start).
- Tunnel: route both names to the listen address; the pairing port stays LAN-only. Devices on other networks pair and sync through the front name (`/relay/`, sealed so the host can't read them; nothing more to open); the host announces that name on the LAN, so devices at home learn it by themselves. The player name must not be redirected to HTTPS: on Cloudflare "Always Use HTTPS" covers the whole zone, so turn it off and redirect the other names with a redirect rule (`not ssl and http.host ne "<player name>"`). Chrome asks once before opening the player (it is plain HTTP).
- Use: the app's Settings → Devices → Web player makes a login link (works once, 10 minutes; its 8-character code can also be typed on the front door's page); a session lasts 3 hours and the page extends it by 3 hours. Safari, Chrome and Edge play the provider's streams directly; Firefox only where the provider allows it.
- Update: `sudo gerdtv-host update` installs the newest release when there is one: it checks the signed `latest.json` like the apps' updater, keeps the old binary as `gerdtv-host.prev`, restarts `gerdtv-host.service` (`--unit` for another name) and goes back to the old binary when the new one isn't still running 30 s later (exit code 1 on any failure). `--before '<command>'` runs first, with the new version in `GERDTV_UPDATE_VERSION`, e.g. a VM snapshot; when it fails, nothing is installed. `gerdtv-host --version` shows the installed version.
- Nightly updates: a oneshot unit `gerdtv-host-update.service` (`ExecStart=/usr/local/bin/gerdtv-host update`, run as root, since the service's user can't write the binary) and a timer with `OnCalendar=*-*-* 03:30` and `Persistent=true`; a failed run leaves the unit failed, for whatever watches your failed units.
- Rollback by hand: `sudo install -m 0755 /usr/local/bin/gerdtv-host.prev /usr/local/bin/gerdtv-host`, then restart the service.

## Checking a download
Each release has `latest.json` with every asset's SHA-256 (signed in `latest.json.sig`); `shasum -a 256 <file>` must match.
