//! Device pairing and sync (owner decision): two gerdTV installs (apps, or the headless host) exchange the open
//! profile, its login, linked services' tokens, the app-wide keys and the user data, directly on the local network,
//! with no server in between.
//!
//! How it fits together:
//! - One side **listens** (`Listener`, a TCP port on all interfaces, announced by mDNS as `_gerdtv._tcp` with the
//!   device's name and platform); the other **connects** (`connect_code` / `connect_peer`).
//! - First time: the listener shows a one-time **code** (12 Crockford base32 characters, 60 bits; also as a QR
//!   `gerdtv://pair?a=<addr:port>&c=<code>`). Both derive the key from it; a wrong code fails the first sealed frame
//!   and burns the code (one attempt), and a code is good for 10 minutes. The connector sends a fresh random 32-byte
//!   key along, which both keep for later syncs: from then on the peers are **remembered** and connect by device id.
//! - Every connection gets its own key: SHA-256 over the base key (code or peer key) and a random salt the connector
//!   sends in clear, so a remembered peer key never repeats a nonce across connections. Frames are sealed with
//!   ChaCha20-Poly1305; the nonce is the direction plus a counter.
//! - Order: connector → header (clear: version, salt, its device id for a remembered peer), then sealed: connector's
//!   hello (device, new key), listener's hello (device; the connector can ask its user "send to X?" now), connector's
//!   bundle, listener's bundle. Both then merge the other's bundle (`apply`): a two-way sync, newer wins.
//!
//! Merge rules (`merge_keys`, `apply`): the profile and its login are taken when the other's `updated_at` is newer
//! (an unknown profile is added); linked services' tokens fill only what is missing here; the app-wide keys (TMDB,
//! OpenSubtitles) are taken whole when the other side changed them later, else only fill gaps; user data goes through
//! the export/import merge (userdata.rs: newer rows win, nothing is deleted).
//!
//! Debugging: nothing here logs a bundle (it carries logins). A "wrong or used code" with the right code means the
//! code was burnt by an earlier attempt or ran out: the listener shows a new one. Two devices that don't find each
//! other by mDNS (guest Wi-Fi, client isolation) still pair by the QR, which carries the address.

use crate::library::{self, Library, LibraryError, Profile, SourceKind};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedSender;

/// The mDNS service type the listener announces.
pub const SERVICE: &str = "_gerdtv._tcp.local.";
/// Crockford's base32: no I, L, O or U, so a typed code can't be misread (typing those still works, see `normalize`).
const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_LEN: usize = 12;
/// How long a code works.
pub const CODE_TTL: Duration = Duration::from_secs(10 * 60);
/// The largest frame accepted (user data of a big profile is a few hundred KB).
const MAX_FRAME: usize = 32 << 20;
/// How long either side waits for the other's next frame; the connector's user may be confirming meanwhile.
const STEP_TIMEOUT: Duration = Duration::from_secs(120);
const VERSION: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    #[error("wrong or used code")]
    Auth,
    #[error("this device is not paired with the other one")]
    UnknownPeer,
    #[error("the other device answered something unexpected")]
    Protocol,
    #[error("the other device took too long")]
    Timeout,
    #[error(transparent)]
    Library(#[from] LibraryError),
}

pub type Result<T> = std::result::Result<T, PairError>;

/// A gerdTV install as the other side sees it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    /// Random, made once per install.
    pub id: String,
    /// For people: the computer's name or the platform.
    pub name: String,
    pub platform: String,
}

/// A remembered device: its key and where it was last reached (mDNS finds the current address; iOS doesn't announce
/// itself, so the last address is the fallback).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Peer {
    pub device: Device,
    /// 32 bytes, hex.
    pub key: String,
    pub addr: String,
    /// A headless host's web player address (its front door, e.g. "https://tv.example.org"); "" for apps.
    #[serde(default)]
    pub web: String,
}

/// What this device has to offer, as its owner (the app's secure storage, the host's file) keeps it.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct LocalSecrets {
    /// TMDB, OpenSubtitles (key and login), by name.
    pub app_keys: BTreeMap<String, String>,
    /// When the app keys were last changed here (unix seconds; 0 = never).
    pub keys_updated_at: i64,
    /// The open profile: its id, login and linked services' tokens (premiumize, trakt, simkl).
    pub profile: Option<ProfileSecrets>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ProfileSecrets {
    pub id: String,
    pub login: Vec<String>,
    pub services: BTreeMap<String, String>,
}

/// What travels (sealed).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Bundle {
    pub app_keys: BTreeMap<String, String>,
    pub keys_updated_at: i64,
    pub profile: Option<ProfileBundle>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileBundle {
    pub profile: Profile,
    pub login: Vec<String>,
    pub services: BTreeMap<String, String>,
    /// userdata.rs's export.
    pub user_data: String,
}

/// What a sync changed here, for the owner to store (secrets live outside the core) and show.
#[derive(Debug, Clone, PartialEq)]
pub struct Applied {
    pub peer: Device,
    /// Where the peer listens ("ip:port"), when it said so: kept for the next sync (iOS doesn't announce itself).
    pub peer_addr: Option<String>,
    /// The peer's web player address, when it is a host.
    pub peer_web: Option<String>,
    /// A new pairing: the key to remember for `peer` (the address is the owner's to add).
    pub new_key: Option<String>,
    /// The app keys to store when they changed (with their time).
    pub app_keys: Option<(BTreeMap<String, String>, i64)>,
    pub profile: Option<AppliedProfile>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AppliedProfile {
    pub profile: Profile,
    /// The login to store when it changed (or the profile is new here).
    pub login: Option<Vec<String>>,
    /// The services' tokens to store (only ones that were missing here).
    pub services: BTreeMap<String, String>,
    pub added: bool,
}

/// Everything a side needs for a sync: where its profiles are, who it is, its secrets.
#[derive(Debug, Clone)]
pub struct Local {
    pub dir: PathBuf,
    pub me: Device,
    pub secrets: LocalSecrets,
    pub peers: Vec<Peer>,
    /// This side's listener port, told to the other side (None: not listening).
    pub port: Option<u16>,
    /// A host's web player address, told to the other side (None: an app).
    pub web: Option<String>,
}

// ---- codes and keys ----

/// Reads `N` random bytes from the system (every target platform has /dev/urandom: Linux, Android, macOS, iOS).
pub fn random<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut b))
        .expect("system randomness");
    b
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    s.len()
        .is_multiple_of(2)
        .then(|| {
            (0..s.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
                .collect()
        })
        .flatten()
}

/// A new install's device id.
pub fn new_device_id() -> String {
    hex(&random::<8>())
}

/// A fresh code (12 characters, shown as `ABCD-EFGH-JKMN`).
pub fn new_code() -> String {
    random::<CODE_LEN>()
        .iter()
        .map(|b| ALPHABET[(b & 31) as usize] as char)
        .collect()
}

/// Shown and printed in groups of four.
pub fn format_code(code: &str) -> String {
    code.as_bytes()
        .chunks(4)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

/// A typed or scanned code as the key needs it: case, dashes and spaces don't matter, O/I/L read as 0/1/1.
pub fn normalize(code: &str) -> String {
    code.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            c => c,
        })
        .collect()
}

fn code_key(code: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"gerdtv-pair-v1");
    h.update(normalize(code).as_bytes());
    h.finalize().into()
}

fn session_key(base: &[u8], salt: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"gerdtv-session-v1");
    h.update(base);
    h.update(salt);
    h.finalize().into()
}

/// The QR's text for a listener at `addr` with `code`.
pub fn qr_text(addr: &str, code: &str) -> String {
    format!("gerdtv://pair?a={addr}&c={code}")
}

/// The QR code's modules for `text`, row by row (true = dark), and its width (without the quiet zone).
pub fn qr_modules(text: &str) -> (usize, Vec<bool>) {
    let q = qrcode::QrCode::new(text.as_bytes()).expect("short text fits a QR code");
    let dark = q
        .to_colors()
        .into_iter()
        .map(|c| c == qrcode::Color::Dark)
        .collect();
    (q.width(), dark)
}

/// `gerdtv://pair?a=…&c=…` → (address, code), from the system camera's link.
pub fn parse_pair_link(link: &str) -> Option<(String, String)> {
    let query = link.strip_prefix("gerdtv://pair?")?;
    let mut addr = None;
    let mut code = None;
    for kv in query.split('&') {
        match kv.split_once('=') {
            Some(("a", v)) => addr = Some(v.to_string()),
            Some(("c", v)) => code = Some(v.to_string()),
            _ => {}
        }
    }
    Some((addr?, code?))
}

// ---- sealed frames ----

/// One connection's sealing state: the session key and a counter per direction.
struct Channel {
    stream: TcpStream,
    cipher: ChaCha20Poly1305,
    /// 0 for the connector's frames, 1 for the listener's.
    me: u8,
    sent: u64,
    received: u64,
}

impl Channel {
    fn new(stream: TcpStream, key: [u8; 32], listener: bool) -> Channel {
        Channel {
            stream,
            cipher: ChaCha20Poly1305::new_from_slice(&key).expect("32-byte key"),
            me: listener as u8,
            sent: 0,
            received: 0,
        }
    }

    fn nonce(direction: u8, n: u64) -> Nonce {
        let mut b = [0u8; 12];
        b[0] = direction;
        b[4..].copy_from_slice(&n.to_be_bytes());
        Nonce::from(b)
    }

    async fn send<T: Serialize>(&mut self, value: &T) -> Result<()> {
        let plain = serde_json::to_vec(value).map_err(|_| PairError::Protocol)?;
        let sealed = self
            .cipher
            .encrypt(&Self::nonce(self.me, self.sent), plain.as_slice())
            .map_err(|_| PairError::Protocol)?;
        self.sent += 1;
        write_frame(&mut self.stream, &sealed).await
    }

    async fn receive<T: for<'de> Deserialize<'de>>(&mut self) -> Result<T> {
        let sealed = read_frame(&mut self.stream).await?;
        let plain = self
            .cipher
            .decrypt(&Self::nonce(1 - self.me, self.received), sealed.as_slice())
            .map_err(|_| PairError::Auth)?;
        self.received += 1;
        serde_json::from_slice(&plain).map_err(|_| PairError::Protocol)
    }
}

async fn write_frame(s: &mut TcpStream, data: &[u8]) -> Result<()> {
    s.write_all(&(data.len() as u32).to_be_bytes()).await?;
    s.write_all(data).await?;
    Ok(s.flush().await?)
}

async fn read_frame(s: &mut TcpStream) -> Result<Vec<u8>> {
    let read = async {
        let mut len = [0u8; 4];
        s.read_exact(&mut len).await?;
        let len = u32::from_be_bytes(len) as usize;
        if len > MAX_FRAME {
            return Err(PairError::Protocol);
        }
        let mut buf = vec![0u8; len];
        s.read_exact(&mut buf).await?;
        Ok(buf)
    };
    tokio::time::timeout(STEP_TIMEOUT, read)
        .await
        .map_err(|_| PairError::Timeout)?
}

/// Sent in clear first: which key to use.
#[derive(Serialize, Deserialize)]
struct Header {
    v: u32,
    salt: String,
    /// A remembered peer's device id; absent = a code.
    from: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Hello {
    device: Device,
    /// Where this side listens (its address is the connection's).
    port: Option<u16>,
    /// A host's web player address.
    #[serde(default)]
    web: Option<String>,
    /// Code pairing only: the key both keep.
    new_key: Option<String>,
}

// ---- the two sides ----

/// A connection that said hello: the other side is known, nothing was sent yet (the user confirms now).
pub struct Connection {
    channel: Channel,
    pub peer: Device,
    peer_addr: Option<String>,
    peer_web: Option<String>,
    new_key: Option<String>,
}

/// Connects with a code the other device shows.
pub async fn connect_code(
    addr: &str,
    code: &str,
    me: &Device,
    port: Option<u16>,
) -> Result<Connection> {
    let new_key = hex(&random::<32>());
    connect(addr, code_key(code).to_vec(), None, me, port, Some(new_key)).await
}

/// Connects to a remembered device.
pub async fn connect_peer(
    addr: &str,
    me: &Device,
    port: Option<u16>,
    peer: &Peer,
) -> Result<Connection> {
    let key = unhex(&peer.key).ok_or(PairError::UnknownPeer)?;
    connect(addr, key, Some(me.id.clone()), me, port, None).await
}

async fn connect(
    addr: &str,
    base: Vec<u8>,
    from: Option<String>,
    me: &Device,
    port: Option<u16>,
    new_key: Option<String>,
) -> Result<Connection> {
    let mut stream = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(addr))
        .await
        .map_err(|_| PairError::Timeout)??;
    let salt = random::<16>();
    let header = Header {
        v: VERSION,
        salt: hex(&salt),
        from,
    };
    write_frame(&mut stream, &serde_json::to_vec(&header).unwrap()).await?;
    let mut channel = Channel::new(stream, session_key(&base, &salt), false);
    channel
        .send(&Hello {
            device: me.clone(),
            port,
            web: None,
            new_key: new_key.clone(),
        })
        .await?;
    let hello: Hello = channel.receive().await?;
    let host = addr.rsplit_once(':').map_or(addr, |(h, _)| h);
    Ok(Connection {
        channel,
        peer: hello.device,
        peer_addr: hello.port.map(|p| format!("{host}:{p}")),
        peer_web: hello.web,
        new_key,
    })
}

impl Connection {
    /// Sends this side's bundle, takes the other's and merges it here.
    pub async fn exchange(mut self, local: &Local) -> Result<Applied> {
        let mine = snapshot(local)?;
        self.channel.send(&mine).await?;
        let theirs: Bundle = self.channel.receive().await?;
        let mut a = apply(local, &self.peer, self.new_key, theirs)?;
        a.peer_addr = self.peer_addr;
        a.peer_web = self.peer_web;
        Ok(a)
    }
}

/// The listener's code and when it was made; None = no code accepted (remembered peers only).
#[derive(Default)]
struct CodeState {
    code: Option<(String, Instant)>,
}

/// What the listener reports to its owner.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Applied(Box<Applied>),
    Failed(String),
    /// The code was burnt (a wrong attempt) or ran out: show this one instead.
    NewCode(String),
}

/// A listening device. Stops when dropped.
pub struct Listener {
    pub port: u16,
    codes: Arc<Mutex<CodeState>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Listener {
    /// Listens on every interface (a random port); `local` is read at each connection, so its owner updates it when
    /// the open profile, the secrets or the peers change.
    pub async fn start(
        local: Arc<Mutex<Local>>,
        events: UnboundedSender<Event>,
    ) -> Result<Listener> {
        Self::start_on(local, events, 0).await
    }

    /// [start] on a fixed `port` (0: any): the headless host uses one, so a firewall can allow it.
    pub async fn start_on(
        local: Arc<Mutex<Local>>,
        events: UnboundedSender<Event>,
        port: u16,
    ) -> Result<Listener> {
        let listener = TcpListener::bind(("0.0.0.0", port)).await?;
        let port = listener.local_addr()?.port();
        let codes = Arc::new(Mutex::new(CodeState::default()));
        let c = codes.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, from)) = listener.accept().await else {
                    continue;
                };
                let (local, codes, events) = (local.clone(), c.clone(), events.clone());
                tokio::spawn(async move {
                    match answer(stream, &local, &codes, &events).await {
                        Ok((mut applied, port)) => {
                            applied.peer_addr = port.map(|p| format!("{}:{p}", from.ip()));
                            applied.peer.name.truncate(64);
                            let _ = events.send(Event::Applied(Box::new(applied)));
                        }
                        Err(e) => {
                            let _ = events.send(Event::Failed(e.to_string()));
                        }
                    }
                });
            }
        });
        Ok(Listener { port, codes, task })
    }

    /// Starts accepting a new code (shown to the user) and returns it.
    pub fn new_code(&self) -> String {
        let code = new_code();
        self.codes.lock().unwrap().code = Some((code.clone(), Instant::now()));
        code
    }

    /// Stops accepting codes (the pairing screen closed); remembered peers still sync.
    pub fn clear_code(&self) {
        self.codes.lock().unwrap().code = None;
    }
}

async fn answer(
    mut stream: TcpStream,
    local: &Mutex<Local>,
    codes: &Mutex<CodeState>,
    events: &UnboundedSender<Event>,
) -> Result<(Applied, Option<u16>)> {
    let header: Header =
        serde_json::from_slice(&read_frame(&mut stream).await?).map_err(|_| PairError::Protocol)?;
    if header.v != VERSION {
        return Err(PairError::Protocol);
    }
    let salt = unhex(&header.salt).ok_or(PairError::Protocol)?;
    let base = match &header.from {
        Some(id) => {
            let l = local.lock().unwrap();
            let peer = l.peers.iter().find(|p| &p.device.id == id);
            unhex(&peer.ok_or(PairError::UnknownPeer)?.key).ok_or(PairError::UnknownPeer)?
        }
        None => {
            // One attempt per code: whatever happens next, this code is used up; the user gets a new one.
            let mut c = codes.lock().unwrap();
            let (code, made) = c.code.take().ok_or(PairError::Auth)?;
            let fresh = new_code();
            c.code = Some((fresh.clone(), Instant::now()));
            let _ = events.send(Event::NewCode(fresh));
            if made.elapsed() > CODE_TTL {
                return Err(PairError::Auth);
            }
            code_key(&code).to_vec()
        }
    };
    let mut channel = Channel::new(stream, session_key(&base, &salt), true);
    let hello: Hello = channel.receive().await?;
    // A remembered peer must say who it claimed to be in clear.
    if header
        .from
        .as_ref()
        .is_some_and(|id| id != &hello.device.id)
    {
        return Err(PairError::UnknownPeer);
    }
    let snapshot_local = local.lock().unwrap().clone();
    channel
        .send(&Hello {
            device: snapshot_local.me.clone(),
            port: snapshot_local.port,
            web: snapshot_local.web.clone(),
            new_key: None,
        })
        .await?;
    let theirs: Bundle = channel.receive().await?;
    // This side's state at the moment the other's arrives (its owner may have changed it meanwhile).
    let now_local = local.lock().unwrap().clone();
    channel.send(&snapshot(&now_local)?).await?;
    Ok((
        apply(&now_local, &hello.device, hello.new_key, theirs)?,
        hello.port,
    ))
}

// ---- bundles and merging ----

/// This side's bundle: the app keys and, with a provider, the open profile with its login, services and user data.
pub fn snapshot(local: &Local) -> Result<Bundle> {
    let s = &local.secrets;
    let profile = match &s.profile {
        Some(p) => {
            let profile = library::load_profiles(&local.dir)?
                .into_iter()
                .find(|x| x.id == p.id);
            match profile {
                // A profile without a provider has nothing to give but the keys.
                Some(profile) if profile.source != SourceKind::None => {
                    let lib = Library::open(&local.dir, &p.id, p.login.clone())?;
                    Some(ProfileBundle {
                        user_data: lib.export_user_data()?,
                        profile,
                        login: p.login.clone(),
                        services: p.services.clone(),
                    })
                }
                _ => None,
            }
        }
        None => None,
    };
    Ok(Bundle {
        app_keys: s.app_keys.clone(),
        keys_updated_at: s.keys_updated_at,
        profile,
    })
}

/// The app keys after a sync: the other side's whole set when it changed them later, else ours with its gaps filled.
/// None: nothing changes here.
pub fn merge_keys(
    local: &BTreeMap<String, String>,
    local_at: i64,
    theirs: &BTreeMap<String, String>,
    their_at: i64,
) -> Option<(BTreeMap<String, String>, i64)> {
    let merged = if their_at > local_at {
        (theirs.clone(), their_at)
    } else {
        let mut m = local.clone();
        for (k, v) in theirs {
            m.entry(k.clone()).or_insert_with(|| v.clone());
        }
        (m, local_at)
    };
    (merged.0 != *local || merged.1 != local_at).then_some(merged)
}

/// Merges the other side's bundle here: the profile (and its user data) into the profile store and database, the
/// secrets into the returned `Applied` for the owner to store.
pub fn apply(
    local: &Local,
    peer: &Device,
    new_key: Option<String>,
    theirs: Bundle,
) -> Result<Applied> {
    let s = &local.secrets;
    let app_keys = merge_keys(
        &s.app_keys,
        s.keys_updated_at,
        &theirs.app_keys,
        theirs.keys_updated_at,
    );
    let profile = match theirs.profile {
        None => None,
        Some(b) => {
            let here = library::load_profiles(&local.dir)?
                .into_iter()
                .find(|p| p.id == b.profile.id);
            let known = s.profile.as_ref().filter(|p| p.id == b.profile.id);
            let newer = here.as_ref().is_none_or(|h| {
                b.profile.updated_at > h.updated_at || h.source == SourceKind::None
            });
            if newer {
                library::put_profile(&local.dir, &b.profile)?;
            }
            let services = b
                .services
                .iter()
                .filter(|(k, _)| known.is_none_or(|p| !p.services.contains_key(*k)))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            // Its user data merges row by row either way (the database doesn't check the login).
            let login = if newer {
                b.login.clone()
            } else {
                known.map(|p| p.login.clone()).unwrap_or(b.login.clone())
            };
            Library::open(&local.dir, &b.profile.id, login.clone())?
                .import_user_data(&b.user_data)
                .map_err(|_| PairError::Protocol)?;
            let added = here.is_none();
            Some(AppliedProfile {
                profile: if newer { b.profile } else { here.unwrap() },
                login: (newer && known.is_none_or(|p| p.login != b.login)).then_some(b.login),
                services,
                added,
            })
        }
    };
    Ok(Applied {
        peer: peer.clone(),
        peer_addr: None,
        peer_web: None,
        new_key,
        app_keys,
        profile,
    })
}

// ---- a paired app talking to a host (web player links and sessions) ----
//
// A paired app asks the headless host for a web login link, or lists and ends web sessions, over plain HTTP(S) to the
// host's front door: the request and the answer are sealed with a key derived from their pairing key, so neither a
// proxy nor the network sees or forges them. A request is good once (its random nonce) and for 2 minutes.

/// How long a sealed app request is accepted after it was made (clocks of paired devices are NTP-synced).
pub const APP_REQUEST_TTL: i64 = 120;

fn app_key(peer_key: &[u8]) -> ChaCha20Poly1305 {
    let mut h = Sha256::new();
    h.update(b"gerdtv-app-v1");
    h.update(peer_key);
    ChaCha20Poly1305::new_from_slice(&h.finalize()).expect("32-byte key")
}

/// The answer's nonce: the request's with the top bit of its first byte flipped, so the two never collide.
fn answer_nonce(n: &[u8; 12]) -> [u8; 12] {
    let mut a = *n;
    a[0] ^= 0x80;
    a
}

/// What travels to the host's `/app`: who asks, the nonce, and the sealed request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppEnvelope {
    pub from: String,
    pub nonce: String,
    pub sealed: String,
}

/// A sealed app request's content.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppRequest {
    /// Unix seconds when made.
    pub ts: i64,
    /// "link" (a new login link), "sessions" (the list), "end" (end session `id`).
    pub op: String,
    #[serde(default)]
    pub id: String,
}

/// Seals `req` for the host as `me`, with the pairing key `peer_key` (hex). Returns the envelope and the nonce.
pub fn seal_app_request(
    me: &str,
    peer_key: &str,
    req: &AppRequest,
) -> Option<(AppEnvelope, [u8; 12])> {
    let key = unhex(peer_key)?;
    let nonce = random::<12>();
    let sealed = app_key(&key)
        .encrypt(
            &Nonce::from(nonce),
            serde_json::to_vec(req).ok()?.as_slice(),
        )
        .ok()?;
    Some((
        AppEnvelope {
            from: me.to_string(),
            nonce: hex(&nonce),
            sealed: hex(&sealed),
        },
        nonce,
    ))
}

/// The host's side: opens an envelope from a remembered peer (None: unknown, forged or broken). Freshness and replay
/// are the host's to check (`ts`, the nonce).
pub fn open_app_request(
    peers: &[Peer],
    env: &AppEnvelope,
) -> Option<(AppRequest, [u8; 12], Vec<u8>)> {
    let peer = peers.iter().find(|p| p.device.id == env.from)?;
    let key = unhex(&peer.key)?;
    let nonce: [u8; 12] = unhex(&env.nonce)?.try_into().ok()?;
    let plain = app_key(&key)
        .decrypt(&Nonce::from(nonce), unhex(&env.sealed)?.as_slice())
        .ok()?;
    Some((serde_json::from_slice(&plain).ok()?, nonce, key))
}

/// Seals the host's answer (hex) to a request with `nonce`, under the asking peer's key.
pub fn seal_app_answer(key: &[u8], nonce: &[u8; 12], answer: &serde_json::Value) -> String {
    let sealed = app_key(key)
        .encrypt(
            &Nonce::from(answer_nonce(nonce)),
            answer.to_string().as_bytes(),
        )
        .expect("sealing never fails for small answers");
    hex(&sealed)
}

/// The app's side: sends `req` to the host's front door `web` and opens its answer.
pub async fn app_request(
    web: &str,
    me: &str,
    peer: &Peer,
    req: &AppRequest,
) -> Result<serde_json::Value> {
    let (env, nonce) = seal_app_request(me, &peer.key, req).ok_or(PairError::UnknownPeer)?;
    crate::xtream::ensure_tls_provider();
    let res = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| PairError::Io(std::io::Error::other(e.without_url())))?
        .post(format!("{}/app", web.trim_end_matches('/')))
        .header("content-type", "application/json")
        .body(serde_json::to_vec(&env).map_err(|_| PairError::Protocol)?)
        .send()
        .await
        .map_err(|e| PairError::Io(std::io::Error::other(e.without_url())))?;
    if !res.status().is_success() {
        return Err(PairError::Io(std::io::Error::other(format!(
            "the host answered HTTP {}",
            res.status().as_u16()
        ))));
    }
    let bytes = res.bytes().await.map_err(|_| PairError::Protocol)?;
    let body: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| PairError::Protocol)?;
    open_app_answer(&peer.key, &nonce, body["sealed"].as_str().unwrap_or("")).ok_or(PairError::Auth)
}

/// The app's side: opens the host's sealed answer (hex) to its request with `nonce`; None: forged or broken.
pub fn open_app_answer(
    peer_key: &str,
    nonce: &[u8; 12],
    sealed: &str,
) -> Option<serde_json::Value> {
    let plain = app_key(&unhex(peer_key)?)
        .decrypt(&Nonce::from(answer_nonce(nonce)), unhex(sealed)?.as_slice())
        .ok()?;
    serde_json::from_slice(&plain).ok()
}

/// Unix seconds now.
pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// This device's address on the local network (the one a route to the internet would use), for the QR. A UDP
/// "connection" sends nothing; it only makes the system pick the outgoing interface.
pub fn local_ip() -> Option<String> {
    let s = std::net::UdpSocket::bind(("0.0.0.0", 0)).ok()?;
    s.connect(("192.0.2.1", 9)).ok()?;
    Some(s.local_addr().ok()?.ip().to_string())
}

// ---- mDNS ----

/// A device found on the network.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub device: Device,
    pub addr: String,
}

/// Announces this device's listener while it lives (dropping it withdraws the announcement).
pub struct Advertiser {
    daemon: mdns_sd::ServiceDaemon,
    fullname: String,
}

impl Drop for Advertiser {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}

pub fn advertise(me: &Device, port: u16) -> std::result::Result<Advertiser, String> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    let props = [
        ("id", me.id.as_str()),
        ("name", me.name.as_str()),
        ("platform", me.platform.as_str()),
    ];
    let info = mdns_sd::ServiceInfo::new(
        SERVICE,
        &me.id,
        &format!("gerdtv-{}.local.", me.id),
        "",
        port,
        &props[..],
    )
    .map_err(|e| e.to_string())?
    .enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon.register(info).map_err(|e| e.to_string())?;
    Ok(Advertiser { daemon, fullname })
}

/// The gerdTV devices that answer within `wait` (this one left out by `me`).
pub fn discover(me: &str, wait: Duration) -> std::result::Result<Vec<Found>, String> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    let rx = daemon.browse(SERVICE).map_err(|e| e.to_string())?;
    let end = Instant::now() + wait;
    let mut found: Vec<Found> = Vec::new();
    while let Some(left) = end.checked_duration_since(Instant::now()) {
        let Ok(event) = rx.recv_timeout(left) else {
            break;
        };
        if let mdns_sd::ServiceEvent::ServiceResolved(s) = event {
            let prop = |k: &str| {
                s.txt_properties
                    .get_property_val_str(k)
                    .unwrap_or("")
                    .to_string()
            };
            let Some(ip) = s.get_addresses_v4().into_iter().next() else {
                continue;
            };
            let device = Device {
                id: prop("id"),
                name: prop("name"),
                platform: prop("platform"),
            };
            if device.id != me && !found.iter().any(|f| f.device.id == device.id) {
                found.push(Found {
                    device,
                    addr: format!("{ip}:{}", s.port),
                });
            }
        }
    }
    let _ = daemon.shutdown();
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gerdtv-pair-{name}-{}", new_device_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn device(id: &str) -> Device {
        Device {
            id: id.into(),
            name: format!("Device {id}"),
            platform: "linux".into(),
        }
    }

    /// A side with one Xtream profile `pid` whose user data has `fav` as a favourite.
    fn side(name: &str, pid: Option<&str>, fav: Option<&str>, updated_at: i64) -> Local {
        let dir = tempdir(name);
        let mut secrets = LocalSecrets::default();
        if let Some(pid) = pid {
            let p = Profile {
                id: pid.into(),
                name: format!("Provider of {name}"),
                source: SourceKind::Xtream,
                server: "http://xc.example.invalid".into(),
                user_agent: String::new(),
                max_connections: None,
                updated_at,
            };
            library::put_profile(&dir, &p).unwrap();
            let login = vec![format!("user-{name}"), format!("pass-{name}")];
            let lib = Library::open(&dir, pid, login.clone()).unwrap();
            if let Some(key) = fav {
                lib.set_favourite(key, true).unwrap();
            }
            secrets.profile = Some(ProfileSecrets {
                id: pid.into(),
                login,
                services: BTreeMap::from([(format!("svc-{name}"), "t".to_string())]),
            });
        }
        Local {
            dir,
            me: device(name),
            secrets,
            peers: vec![],
            port: None,
            web: None,
        }
    }

    async fn listen(
        local: Local,
    ) -> (
        Listener,
        Arc<Mutex<Local>>,
        tokio::sync::mpsc::UnboundedReceiver<Event>,
    ) {
        let local = Arc::new(Mutex::new(local));
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (Listener::start(local.clone(), tx).await.unwrap(), local, rx)
    }

    async fn applied(rx: &mut tokio::sync::mpsc::UnboundedReceiver<Event>) -> Applied {
        loop {
            match rx.recv().await.unwrap() {
                Event::Applied(a) => return *a,
                Event::NewCode(_) => continue,
                Event::Failed(e) => panic!("{e}"),
            }
        }
    }

    #[test]
    fn codes_read_forgivingly_and_links_parse() {
        let code = new_code();
        assert_eq!(code.len(), 12);
        assert!(code.bytes().all(|b| ALPHABET.contains(&b)));
        assert_eq!(normalize(&format_code(&code).to_lowercase()), code);
        assert_eq!(normalize("oil0-1"), "01101");
        let link = qr_text("192.0.2.7:4100", &code);
        assert_eq!(
            parse_pair_link(&link),
            Some(("192.0.2.7:4100".into(), code))
        );
        assert_eq!(parse_pair_link("https://example.invalid/?a=1&c=2"), None);
        let (w, m) = qr_modules(&link);
        assert_eq!(m.len(), w * w);
    }

    #[test]
    fn app_keys_merge_newer_whole_else_fill_gaps() {
        let m = |v: &[(&str, &str)]| -> BTreeMap<String, String> {
            v.iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        // (local, local time, theirs, their time) → result (None: unchanged).
        let cases = [
            (
                m(&[("tmdb", "a")]),
                10,
                m(&[("tmdb", "b")]),
                20,
                Some((m(&[("tmdb", "b")]), 20)),
            ),
            (m(&[("tmdb", "a")]), 20, m(&[("tmdb", "b")]), 10, None),
            (
                m(&[("tmdb", "a")]),
                20,
                m(&[("os", "c")]),
                10,
                Some((m(&[("tmdb", "a"), ("os", "c")]), 20)),
            ),
            (m(&[]), 0, m(&[]), 0, None),
            // Removed there later: removed here too.
            (m(&[("tmdb", "a")]), 10, m(&[]), 20, Some((m(&[]), 20))),
        ];
        for (l, la, t, ta, want) in cases {
            assert_eq!(merge_keys(&l, la, &t, ta), want, "{l:?} {la} {t:?} {ta}");
        }
    }

    #[tokio::test]
    async fn pairing_by_code_moves_the_profile_both_ways_merge_and_remembers_the_peer() {
        // The new device (listening, showing the code) has nothing; the phone has the profile and a TMDB key.
        let (listener, shared, mut rx) = listen(side("tv", None, None, 0)).await;
        let code = listener.new_code();
        let mut phone = side("phone", Some("p1"), Some("live:1"), 100);
        phone.secrets.app_keys.insert("tmdb".into(), "k".into());
        phone.secrets.keys_updated_at = 5;
        let addr = format!("127.0.0.1:{}", listener.port);
        let conn = connect_code(
            &addr,
            &format_code(&code).to_lowercase(),
            &phone.me,
            Some(4100),
        )
        .await
        .unwrap();
        assert_eq!(
            conn.peer,
            device("tv"),
            "the phone asks 'send to Device tv?' before sending"
        );
        let mine = conn.exchange(&phone).await.unwrap();
        let theirs = applied(&mut rx).await;
        // The TV got everything: profile (with the phone's time), login, services, keys, user data.
        let tv = shared.lock().unwrap().clone();
        let p = theirs.profile.clone().unwrap();
        assert!(p.added);
        assert_eq!(
            p.login,
            Some(vec!["user-phone".to_string(), "pass-phone".to_string()])
        );
        assert_eq!(p.services.get("svc-phone").map(String::as_str), Some("t"));
        assert_eq!(library::load_profiles(&tv.dir).unwrap()[0].updated_at, 100);
        let lib = Library::open(&tv.dir, "p1", vec!["u".into(), "p".into()]).unwrap();
        assert!(lib.export_user_data().unwrap().contains("live:1"));
        assert_eq!(
            theirs.app_keys.unwrap().0.get("tmdb").map(String::as_str),
            Some("k")
        );
        // Both remember each other with the same key; the phone got nothing it lacked.
        assert!(mine.new_key.is_some() && mine.new_key == theirs.new_key);
        assert_eq!(mine.peer, device("tv"));
        // The TV knows where the phone listens; the phone knows where it reached the TV.
        assert_eq!(theirs.peer_addr.as_deref(), Some("127.0.0.1:4100"));
        assert!(
            mine.peer_addr.is_none(),
            "the TV's local has no port in this test"
        );
        assert!(mine.profile.is_none() && mine.app_keys.is_none());

        // Later, as remembered peers: the phone's favourite added on the TV comes back, no code needed.
        Library::open(&tv.dir, "p1", vec!["u".into(), "p".into()])
            .unwrap()
            .set_favourite("movie:9", true)
            .unwrap();
        let key = mine.new_key.unwrap();
        shared.lock().unwrap().peers = vec![Peer {
            device: phone.me.clone(),
            key: key.clone(),
            addr: String::new(),
            web: String::new(),
        }];
        shared.lock().unwrap().secrets = LocalSecrets {
            profile: Some(ProfileSecrets {
                id: "p1".into(),
                login: vec!["user-phone".into(), "pass-phone".into()],
                services: BTreeMap::new(),
            }),
            ..Default::default()
        };
        listener.clear_code();
        let peer = Peer {
            device: device("tv"),
            key,
            addr: addr.clone(),
            web: String::new(),
        };
        let back = connect_peer(&addr, &phone.me, None, &peer)
            .await
            .unwrap()
            .exchange(&phone)
            .await
            .unwrap();
        applied(&mut rx).await;
        assert!(
            back.profile.unwrap().login.is_none(),
            "same login: nothing to store"
        );
        let phone_lib = Library::open(&phone.dir, "p1", vec!["u".into(), "p".into()]).unwrap();
        assert!(phone_lib.export_user_data().unwrap().contains("movie:9"));

        // A device that isn't remembered can't sync as a peer.
        let stranger = Peer {
            device: device("tv"),
            key: hex(&random::<32>()),
            addr: addr.clone(),
            web: String::new(),
        };
        assert!(
            connect_peer(&addr, &device("other"), None, &stranger)
                .await
                .is_err()
        );
        for d in [&tv.dir, &phone.dir] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }

    #[tokio::test]
    async fn a_wrong_code_burns_the_code_and_a_new_one_shows() {
        let (listener, shared, mut rx) = listen(side("tv", None, None, 0)).await;
        let code = listener.new_code();
        let phone = side("phone", Some("p1"), None, 1);
        let addr = format!("127.0.0.1:{}", listener.port);
        let wrong = if code.starts_with('A') { "B" } else { "A" }.to_string() + &code[1..];
        assert!(matches!(
            connect_code(&addr, &wrong, &phone.me, None).await,
            Err(PairError::Auth | PairError::Io(_))
        ));
        let Event::NewCode(fresh) = rx.recv().await.unwrap() else {
            panic!("a new code first")
        };
        assert_ne!(fresh, code);
        // The old code doesn't work any more, even typed right.
        assert!(connect_code(&addr, &code, &phone.me, None).await.is_err());
        // No code at all accepted once pairing is closed.
        listener.clear_code();
        assert!(connect_code(&addr, &fresh, &phone.me, None).await.is_err());
        assert!(
            library::load_profiles(&shared.lock().unwrap().dir)
                .unwrap()
                .is_empty()
        );
        std::fs::remove_dir_all(&phone.dir).unwrap();
    }

    #[test]
    fn app_requests_open_only_for_the_paired_key_and_answers_only_for_the_asker() {
        let key = hex(&random::<32>());
        let peers = vec![Peer {
            device: device("phone"),
            key: key.clone(),
            addr: String::new(),
            web: String::new(),
        }];
        let req = AppRequest {
            ts: 5,
            op: "link".into(),
            id: String::new(),
        };
        let (env, nonce) = seal_app_request("phone", &key, &req).unwrap();
        let (opened, n, k) = open_app_request(&peers, &env).unwrap();
        assert_eq!((opened, n), (req.clone(), nonce));
        // Another key, another sender, or a changed byte: nothing opens.
        let (other, _) = seal_app_request("phone", &hex(&random::<32>()), &req).unwrap();
        assert!(open_app_request(&peers, &other).is_none());
        let mut forged = env.clone();
        forged.from = "tv".into();
        assert!(open_app_request(&peers, &forged).is_none());
        let mut flipped = env.clone();
        flipped.sealed.replace_range(
            0..2,
            if &env.sealed[0..2] == "00" {
                "01"
            } else {
                "00"
            },
        );
        assert!(open_app_request(&peers, &flipped).is_none());
        // The answer opens with the request's nonce flipped, under the same key.
        let a = seal_app_answer(&k, &nonce, &serde_json::json!({"url": "x"}));
        let plain = app_key(&k)
            .decrypt(
                &Nonce::from(answer_nonce(&nonce)),
                unhex(&a).unwrap().as_slice(),
            )
            .unwrap();
        assert_eq!(plain, br#"{"url":"x"}"#);
    }

    #[test]
    fn an_older_profile_keeps_this_sides_login_but_merges_user_data() {
        let here = side("here", Some("p1"), Some("live:1"), 200);
        let there = side("there", Some("p1"), Some("live:2"), 100);
        let bundle = snapshot(&there).unwrap();
        let a = apply(&here, &there.me, None, bundle).unwrap();
        let p = a.profile.unwrap();
        assert!(!p.added && p.login.is_none());
        assert_eq!(p.profile.name, "Provider of here");
        // Services fill only what's missing here.
        assert_eq!(p.services.keys().collect::<Vec<_>>(), ["svc-there"]);
        let lib = Library::open(&here.dir, "p1", vec!["u".into(), "p".into()]).unwrap();
        let data = lib.export_user_data().unwrap();
        assert!(data.contains("live:1") && data.contains("live:2"));
        for d in [&here.dir, &there.dir] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }
}
