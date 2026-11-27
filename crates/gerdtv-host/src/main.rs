//! `gerdtv-host`: the headless host's command line (lib.rs explains the parts; docs/INSTALL.md the setup).
//!
//!   gerdtv-host pair  --dir <state> --front <https://…> [--pair-port 8791]
//!                     shows a code and QR; a gerdTV app pairs, sends its profile and learns the web address
//!   gerdtv-host serve --dir <state> --front <https://…> --player <http://…> [--listen 127.0.0.1:8790] [--proxy <ip>]
//!                     [--pair-port 8791]
//! `--pair-port`: where paired apps reach it for syncs (TCP on every interface; allow it from the LAN only).
//!
//!   gerdtv-host update [--unit gerdtv-host.service] [--before <command>]   as root: newest release, see update.rs
//!   gerdtv-host --version                                 the installed binary's version
//!
//! `serve` keeps the profile in sync (at start, then every 12 h; the guide hourly when due), listens for paired apps'
//! syncs (Sync now) and serves the web player. Logs go to stderr (the journal under systemd).

use gerdtv_core::pairing::{self, Event, Listener};
use gerdtv_host::{Config, Host, HostFile};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// This binary's version (the workspace's, 0.YYMMDD.<PR#>; the same as the release tag without the v).
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn usage() -> ! {
    eprintln!(
        "usage: gerdtv-host pair --dir <state> --front <https://…> [--pair-port 8791]\n       gerdtv-host serve --dir <state> \
         --front <https://…> --player <http://…> [--listen 127.0.0.1:8790] [--proxy <tunnel ip>] [--pair-port 8791]\n       \
         gerdtv-host update [--unit gerdtv-host.service] [--before <command>]\n       gerdtv-host --version"
    );
    std::process::exit(2)
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    // These two need no state folder.
    match args.first().map(String::as_str) {
        Some("--version") => {
            println!("gerdtv-host {VERSION}");
            return;
        }
        Some("update") => {
            let unit = flag("--unit").unwrap_or_else(|| "gerdtv-host.service".into());
            return self_update(&unit, flag("--before").as_deref()).await;
        }
        _ => {}
    }
    let Some(dir) = flag("--dir") else { usage() };
    let cfg = Config {
        dir: dir.into(),
        front: flag("--front").unwrap_or_default(),
        player: flag("--player").unwrap_or_default(),
        listen: flag("--listen").unwrap_or_else(|| "127.0.0.1:8790".into()),
        proxy: flag("--proxy").and_then(|p| p.parse().ok()),
    };
    let file = HostFile::load(&cfg.dir).unwrap_or_else(|e| {
        eprintln!("host: can't read host.json: {e}");
        std::process::exit(1)
    });
    let pair_port: u16 = flag("--pair-port")
        .and_then(|p| p.parse().ok())
        .unwrap_or(8791);
    match args.first().map(String::as_str) {
        // The front address goes out with the pairing (the first sync): the app shows its Web player entry from it.
        Some("pair") if !cfg.front.is_empty() => pair(cfg, file, pair_port).await,
        Some("serve") if !cfg.front.is_empty() && !cfg.player.is_empty() => {
            serve(cfg, file, pair_port).await
        }
        _ => usage(),
    }
}

/// A listener for pairing events that stores what came; `code` also accepts a code (pairing) instead of only peers.
async fn listen(
    host: &Arc<Host>,
    code: bool,
    port: u16,
) -> (Listener, tokio::sync::mpsc::UnboundedReceiver<Event>) {
    let local = Arc::new(Mutex::new(host.local(None)));
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let l = Listener::start_on(local.clone(), tx, port)
        .await
        .unwrap_or_else(|e| {
            eprintln!("host: can't listen for devices: {e}");
            std::process::exit(1)
        });
    *local.lock().unwrap() = host.local(Some(l.port));
    if code {
        let c = l.new_code();
        let ip = pairing::local_ip().unwrap_or_else(|| "127.0.0.1".into());
        // The host pairs on its own network only (it is the relay; it does not ring itself).
        let link = pairing::qr_text(&format!("{ip}:{}", l.port), &c, None);
        println!("{}", qr_text_art(&link));
        println!(
            "Code: {}  (gerdTV: Settings → Account → Devices & sync)",
            pairing::format_code(&c)
        );
    }
    // Kept up to date for the next connection.
    let h = host.clone();
    let port = l.port;
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            *local.lock().unwrap() = h.local(Some(port));
        }
    });
    (l, rx)
}

/// Stores a finished sync and reopens the profile when its login or the profile changed.
fn stored(host: &Host, e: Event) -> bool {
    match e {
        Event::Applied(a) => {
            let mut f = host.file.lock().unwrap();
            f.store(&a);
            if let Err(e) = f.save(&host.cfg.dir) {
                eprintln!("host: can't write host.json: {e}");
            }
            drop(f);
            if a.profile.is_some() {
                host.reopen();
            }
            eprintln!("host: synced with {}", a.peer.name);
            true
        }
        Event::Failed(e) => {
            eprintln!("host: a device sync failed: {e}");
            false
        }
        Event::NewCode(c) => {
            println!("New code: {}", pairing::format_code(&c));
            false
        }
    }
}

async fn pair(cfg: Config, mut file: HostFile, port: u16) {
    file.device();
    let host = Host::new(cfg, file);
    let (_l, mut rx) = listen(&host, true, port).await;
    let _ad = pairing::advertise(&host.local(None).me, _l.port, Some(&host.cfg.front)).ok();
    while let Some(e) = rx.recv().await {
        if stored(&host, e) {
            println!("Paired. Start the service now.");
            return;
        }
    }
}

async fn serve(cfg: Config, mut file: HostFile, port: u16) {
    // Which version runs (the installed one can be newer until the restart): journalctl -u gerdtv-host.
    eprintln!("host: gerdtv-host {VERSION}");
    file.device();
    let host = Host::new(cfg, file);
    if host.lib().is_none() {
        eprintln!("host: no profile yet: run `gerdtv-host pair` first");
        std::process::exit(1);
    }
    let (l, mut rx) = listen(&host, false, port).await;
    let _ad = pairing::advertise(&host.local(None).me, l.port, Some(&host.cfg.front)).ok();
    let h = host.clone();
    tokio::spawn(async move {
        while let Some(e) = rx.recv().await {
            stored(&h, e);
        }
    });
    // The catalogue at start and every 12 h; the guide checked hourly (it refreshes only what is due).
    let h = host.clone();
    tokio::spawn(async move {
        let mut tick = 0u64;
        loop {
            if let Some(lib) = h.lib() {
                if tick.is_multiple_of(12) {
                    match lib.sync().await {
                        Ok(r) => eprintln!("host: synced {} entries", r.stats.entries),
                        Err(e) => eprintln!("host: sync failed: {e}"),
                    }
                }
                if let Err(e) = lib.refresh_guide(7, false).await {
                    eprintln!("host: guide refresh failed: {e}");
                }
            }
            tick += 1;
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    });
    if let Err(e) = gerdtv_host::serve(host).await {
        eprintln!("host: web server stopped: {e}");
        std::process::exit(1);
    }
}

/// `update`: see update.rs. Exit code 1 on any failure, so the timer's unit shows as failed (and is reported).
async fn self_update(unit: &str, before: Option<&str>) {
    let bin = std::env::current_exe().unwrap_or_else(|e| {
        eprintln!("update: can't find this binary: {e}");
        std::process::exit(1)
    });
    let key = gerdtv_core::update::PUBLIC_KEY_HEX;
    let restart = || restart_and_watch(unit);
    match gerdtv_host::update::run(
        gerdtv_core::update::RELEASES,
        key,
        VERSION,
        &bin,
        before,
        restart,
    )
    .await
    {
        Ok(gerdtv_host::update::Outcome::UpToDate) => eprintln!("update: {VERSION} is the newest"),
        Ok(gerdtv_host::update::Outcome::Updated { to }) => eprintln!("update: {to} runs"),
        Err(e) => {
            eprintln!("update: {e}");
            std::process::exit(1)
        }
    }
}

/// Restarts `unit` and waits 30 s: it stayed up if it is active and systemd didn't restart it again meanwhile
/// (NRestarts counts automatic restarts since the last manual start; a crash loop raises it, `Restart=always`).
fn restart_and_watch(unit: &str) -> bool {
    let systemctl = |args: &[&str]| {
        Command::new("systemctl")
            .args(args)
            .output()
            .map(|o| {
                (
                    o.status.success(),
                    String::from_utf8_lossy(&o.stdout).trim().to_string(),
                )
            })
            .unwrap_or((false, String::new()))
    };
    if !systemctl(&["restart", unit]).0 {
        return false;
    }
    let restarts = || systemctl(&["show", "-p", "NRestarts", "--value", unit]).1;
    let before = restarts();
    std::thread::sleep(Duration::from_secs(30));
    systemctl(&["is-active", "--quiet", unit]).0 && restarts() == before
}

/// The QR as text for a terminal: two module rows per line with half blocks, dark on light, with a quiet zone.
fn qr_text_art(text: &str) -> String {
    let (w, m) = pairing::qr_modules(text);
    let quiet = 2usize;
    let dark = |x: isize, y: isize| {
        x >= 0 && y >= 0 && (x as usize) < w && (y as usize) < w && m[y as usize * w + x as usize]
    };
    let mut out = String::new();
    let span = (w + 2 * quiet) as isize;
    let mut y = -(quiet as isize);
    while y < span - quiet as isize {
        for x in -(quiet as isize)..span - quiet as isize {
            // Light background: a dark module prints as a space on an inverted terminal; keep it simple with blocks.
            out.push(match (dark(x, y), dark(x, y + 1)) {
                (true, true) => ' ',
                (true, false) => '▄',
                (false, true) => '▀',
                (false, false) => '█',
            });
        }
        out.push('\n');
        y += 2;
    }
    out
}
