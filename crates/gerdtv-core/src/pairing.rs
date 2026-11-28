//! Device pairing and sync (owner decision): two gerdTV installs (apps, or the headless host) exchange the open
//! profile, its login, linked services' tokens, the app-wide keys and the user data, directly on the local network,
//! with no server in between; across networks they meet at the user's own host, which only forwards the sealed
//! frames (relay.rs; the LAN is always tried first).
//!
//! How it fits together:
//! - One side **listens** (`Listener`, a TCP port on all interfaces, announced by mDNS as `_gerdtv._tcp` with the
//!   device's name and platform); the other **connects** (`connect_code` / `connect_peer`).
//! - First time: the listener shows a one-time **code** (6 digits, owner decision; also as a QR
//!   `gerdtv://pair?a=<addr:port>&c=<code>`, plus `&r=<host's front address>&m=<doorbell>` when a relay is known). The code isn't the key: both sides run SPAKE2 with it (a password-
//!   authenticated key exchange, the RustCrypto `spake2` crate) and get a strong shared key only when both typed the
//!   same code. Someone who recorded the traffic can't try the million codes offline; someone who joins in gets one
//!   guess: a wrong code fails the first sealed frame and burns the code (one attempt), and a code is good for 10
//!   minutes. The connector sends a fresh random 32-byte key along, which both keep for later syncs: from then on the
//!   peers are **remembered** and connect by device id (no code, no SPAKE2).
//! - Every connection gets its own key: SHA-256 over the base key (code or peer key) and two random salts sent in
//!   clear, one from each side. The listener's salt means a recorded connection replayed later gets another key (its
//!   frames don't open, and the listener never seals twice under one key and nonce). Frames are sealed with
//!   ChaCha20-Poly1305; the nonce is the direction plus a counter.
//! - Order: connector → header (clear: version, salt, its device id for a remembered peer, or its SPAKE2 message
//!   for a code), listener → its salt and, for a code, its SPAKE2 message (clear), then sealed: connector's
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
//! other by mDNS (guest Wi-Fi, client isolation) still pair by the QR, which carries the address, and through the
//! relay when the QR names one. The transport is a [Pipe]: a TCP stream on the LAN or a [RelayPipe].

use crate::library::{self, Library, LibraryError, Profile, SourceKind};
use crate::relay::{Relay, RelayPipe};
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
/// Digits only (owner decision: easy on a TV remote's number pad); with SPAKE2 one guess per code is all anyone gets.
const CODE_LEN: usize = 6;
/// SPAKE2's roles: the connector is side A, the listener side B (both must name them the same way).
const SPAKE_A: &[u8] = b"gerdtv-connector";
const SPAKE_B: &[u8] = b"gerdtv-listener";
/// A SPAKE2 message (Ed25519 group): a side byte and a point.
const SPAKE_MSG: usize = 33;
/// How long a code works.
pub const CODE_TTL: Duration = Duration::from_secs(10 * 60);
/// The largest frame accepted (user data of a big profile is a few hundred KB).
const MAX_FRAME: usize = 32 << 20;
/// How long either side waits for the other's next frame; the connector's user may be confirming meanwhile.
const STEP_TIMEOUT: Duration = Duration::from_secs(120);
/// 3: codes go through SPAKE2 (2 hashed the code itself into the key).
const VERSION: u32 = 3;

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    #[error("wrong or used code")]
    Auth,
    #[error("this device is not paired with the other one")]
    UnknownPeer,
    #[error("the other device answered something unexpected (is gerdTV up to date on both?)")]
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
    /// The login to store: when the profile came newer or is new here, and the login differs from the open one's.
    /// An older profile's login never overwrites one stored here (an app keeps several profiles' logins).
    pub login: Option<Vec<String>>,
    /// The login that came, whatever its age: for a side that keeps one profile and has none stored for this one
    /// (the host switching back to a profile it held before, HostFile::store).
    pub incoming_login: Vec<String>,
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

/// Lower-case hex only, so one value has one spelling (the host's replay check compares nonces as text).
fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) || !s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

/// A new install's device id.
pub fn new_device_id() -> String {
    hex(&random::<8>())
}

/// A fresh code (6 digits, shown as `482 913`). Each digit comes from a byte below 250, so all ten are equally likely.
pub fn new_code() -> String {
    let mut code = String::with_capacity(CODE_LEN);
    while code.len() < CODE_LEN {
        for b in random::<16>() {
            if b < 250 && code.len() < CODE_LEN {
                code.push(char::from(b'0' + b % 10));
            }
        }
    }
    code
}

/// Shown and printed in two groups of three.
pub fn format_code(code: &str) -> String {
    code.as_bytes()
        .chunks(3)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// A typed or scanned code as SPAKE2 needs it: spaces and dashes don't matter, O/I/L read as 0/1/1.
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

/// This side's half of SPAKE2 for `code`: the state to finish with and the message for the other side.
fn spake_start(code: &str, listener: bool) -> (spake2::Spake2<spake2::Ed25519Group>, Vec<u8>) {
    let password = spake2::Password::new(normalize(code).as_bytes());
    let (a, b) = (
        spake2::Identity::new(SPAKE_A),
        spake2::Identity::new(SPAKE_B),
    );
    if listener {
        spake2::Spake2::<spake2::Ed25519Group>::start_b(&password, &a, &b)
    } else {
        spake2::Spake2::<spake2::Ed25519Group>::start_a(&password, &a, &b)
    }
}

/// The shared key from the other side's SPAKE2 message (another code gives another key: the first sealed frame
/// then fails, which is the Auth error); a malformed message is a protocol error.
fn spake_finish(state: spake2::Spake2<spake2::Ed25519Group>, theirs: &[u8]) -> Result<Vec<u8>> {
    state.finish(theirs).map_err(|_| PairError::Protocol)
}

/// The connection's key: the base key and both sides' salts (the connector's first, then the listener's).
fn session_key(base: &[u8], connector: &[u8], listener: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"gerdtv-session-v2");
    h.update(base);
    h.update(connector);
    h.update(listener);
    h.finalize().into()
}

/// The QR's text for a listener at `addr` with `code`, and where to meet it when the LAN doesn't reach it.
pub fn qr_text(addr: &str, code: &str, relay: Option<&Relay>) -> String {
    let mut t = format!("gerdtv://pair?a={addr}&c={code}");
    if let Some(r) = relay {
        t.push_str(&format!("&r={}&m={}", escape(&r.web), r.bell));
    }
    t
}

/// Percent-escapes what would end a query value (the relay's address); the rest of a URL stays readable.
fn escape(s: &str) -> String {
    s.replace('%', "%25")
        .replace('&', "%26")
        .replace('=', "%3D")
}

fn unescape(s: &str) -> String {
    s.replace("%3D", "=")
        .replace("%26", "&")
        .replace("%25", "%")
}

/// What a pairing link says: the listener's LAN address, its code, and its relay if it named one.
#[derive(Debug, Clone, PartialEq)]
pub struct PairLink {
    pub addr: String,
    pub code: String,
    pub relay: Option<Relay>,
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

/// `gerdtv://pair?a=…&c=…[&r=…&m=…]`, from the system camera's link.
pub fn parse_pair_link(link: &str) -> Option<PairLink> {
    let query = link.strip_prefix("gerdtv://pair?")?;
    let (mut addr, mut code, mut web, mut bell) = (None, None, None, None);
    for kv in query.split('&') {
        match kv.split_once('=') {
            Some(("a", v)) => addr = Some(v.to_string()),
            Some(("c", v)) => code = Some(v.to_string()),
            Some(("r", v)) => web = Some(unescape(v)),
            Some(("m", v)) => bell = Some(v.to_string()),
            _ => {}
        }
    }
    let relay = match (web, bell) {
        (Some(web), Some(bell)) if !web.is_empty() && !bell.is_empty() => Some(Relay { web, bell }),
        _ => None,
    };
    Some(PairLink {
        addr: addr?,
        code: code?,
        relay,
    })
}

// ---- sealed frames ----

/// How frames travel: a TCP stream on the LAN (length-prefixed), or the host's relay (one message per frame).
pub enum Pipe {
    Tcp(TcpStream),
    Relay(Box<RelayPipe>),
}

/// One connection's sealing state: the session key and a counter per direction.
struct Channel {
    stream: Pipe,
    cipher: ChaCha20Poly1305,
    /// 0 for the connector's frames, 1 for the listener's.
    me: u8,
    sent: u64,
    received: u64,
}

impl Channel {
    fn new(stream: Pipe, key: [u8; 32], listener: bool) -> Channel {
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

async fn write_frame(p: &mut Pipe, data: &[u8]) -> Result<()> {
    match p {
        Pipe::Tcp(s) => {
            s.write_all(&(data.len() as u32).to_be_bytes()).await?;
            s.write_all(data).await?;
            Ok(s.flush().await?)
        }
        Pipe::Relay(r) => Ok(r.send(data).await?),
    }
}

async fn read_frame(p: &mut Pipe) -> Result<Vec<u8>> {
    let read = async {
        let buf = match p {
            Pipe::Tcp(s) => {
                let mut len = [0u8; 4];
                s.read_exact(&mut len).await?;
                let len = u32::from_be_bytes(len) as usize;
                if len > MAX_FRAME {
                    return Err(PairError::Protocol);
                }
                let mut buf = vec![0u8; len];
                s.read_exact(&mut buf).await?;
                buf
            }
            Pipe::Relay(r) => r.receive().await?,
        };
        if buf.len() > MAX_FRAME {
            return Err(PairError::Protocol);
        }
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
    /// A code: the connector's SPAKE2 message, hex.
    #[serde(default)]
    spake: Option<String>,
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

/// Connects with a code the other device shows: at `addr` on the LAN (empty: unknown), else through `relay`.
pub async fn connect_code(
    addr: &str,
    code: &str,
    me: &Device,
    port: Option<u16>,
    relay: Option<&Relay>,
) -> Result<Connection> {
    let new_key = hex(&random::<32>());
    connect(addr, relay, Base::Code(code), me, port, Some(new_key)).await
}

/// Connects to a remembered device: at `addr` on the LAN (empty: unknown), else through `relay`.
pub async fn connect_peer(
    addr: &str,
    me: &Device,
    port: Option<u16>,
    peer: &Peer,
    relay: Option<&Relay>,
) -> Result<Connection> {
    let key = unhex(&peer.key).ok_or(PairError::UnknownPeer)?;
    connect(addr, relay, Base::Peer(key), me, port, None).await
}

/// How long the LAN gets before the relay is tried (alone: the old 10 s; with a relay waiting less, so a phone away
/// from home doesn't stall).
const LAN_TIMEOUT: Duration = Duration::from_secs(10);
const LAN_TIMEOUT_BEFORE_RELAY: Duration = Duration::from_secs(4);

/// The LAN first, then the relay (owner decision: local sync stays the normal way). The error is the last one tried.
async fn open_pipe(addr: &str, relay: Option<&Relay>) -> Result<Pipe> {
    let mut last = PairError::Timeout;
    if !addr.is_empty() {
        let wait = if relay.is_some() {
            LAN_TIMEOUT_BEFORE_RELAY
        } else {
            LAN_TIMEOUT
        };
        match tokio::time::timeout(wait, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => return Ok(Pipe::Tcp(s)),
            Ok(Err(e)) => last = PairError::Io(e),
            Err(_) => {}
        }
    }
    match relay {
        Some(r) => Ok(Pipe::Relay(Box::new(RelayPipe::ring(r).await?))),
        None => Err(last),
    }
}

/// Where the connection's base key comes from.
enum Base<'a> {
    /// A typed or scanned code: SPAKE2 with the listener.
    Code(&'a str),
    /// A remembered peer's key.
    Peer(Vec<u8>),
}

async fn connect(
    addr: &str,
    relay: Option<&Relay>,
    base: Base<'_>,
    me: &Device,
    port: Option<u16>,
    new_key: Option<String>,
) -> Result<Connection> {
    let mut stream = open_pipe(addr, relay).await?;
    // Through the relay the other side's LAN address stays unknown (the next sync finds it by mDNS or the relay).
    let lan = matches!(stream, Pipe::Tcp(_));
    let salt = random::<16>();
    let (spake, from) = match &base {
        Base::Code(code) => (Some(spake_start(code, false)), None),
        Base::Peer(_) => (None, Some(me.id.clone())),
    };
    let header = Header {
        v: VERSION,
        salt: hex(&salt),
        from,
        spake: spake.as_ref().map(|(_, msg)| hex(msg)),
    };
    write_frame(&mut stream, &serde_json::to_vec(&header).unwrap()).await?;
    // The listener's salt, and its SPAKE2 message for a code.
    let reply = read_frame(&mut stream).await?;
    let expected = 16 + if spake.is_some() { SPAKE_MSG } else { 0 };
    if reply.len() != expected {
        return Err(PairError::Protocol);
    }
    let (theirs, their_spake) = reply.split_at(16);
    let base = match (base, spake) {
        (Base::Peer(key), _) => key,
        (Base::Code(_), Some((state, _))) => spake_finish(state, their_spake)?,
        (Base::Code(_), None) => unreachable!("a code always starts SPAKE2"),
    };
    let mut channel = Channel::new(stream, session_key(&base, &salt, theirs), false);
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
        peer_addr: hello.port.filter(|_| lan).map(|p| format!("{host}:{p}")),
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
    local: Arc<Mutex<Local>>,
    events: UnboundedSender<Event>,
    task: tokio::task::JoinHandle<()>,
    /// Replaces a shown code once it runs out, so the screen never shows one that can't work.
    rotate: tokio::task::JoinHandle<()>,
    /// The doorbell at the relay while one is set ([Listener::set_relay]).
    bell: Mutex<Option<(Relay, tokio::task::JoinHandle<()>)>>,
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.task.abort();
        self.rotate.abort();
        if let Some((_, t)) = self.bell.lock().unwrap().take() {
            t.abort();
        }
    }
}

/// After a failed doorbell poll (the host down, no network): wait this long before the next, not a busy loop.
const BELL_RETRY: Duration = Duration::from_secs(30);

/// Answers one connection (TCP or relayed) and reports how it went; `from` is the LAN address, None when relayed.
/// Returns whether it failed.
async fn answer_and_report(
    pipe: Pipe,
    from: Option<std::net::IpAddr>,
    local: Arc<Mutex<Local>>,
    codes: Arc<Mutex<CodeState>>,
    events: UnboundedSender<Event>,
) -> bool {
    match answer(pipe, &local, &codes, &events).await {
        Ok((mut applied, port)) => {
            applied.peer_addr = from.zip(port).map(|(ip, p)| format!("{ip}:{p}"));
            applied.peer.name.truncate(64);
            let _ = events.send(Event::Applied(Box::new(applied)));
            false
        }
        Err(e) => {
            let _ = events.send(Event::Failed(e.to_string()));
            true
        }
    }
}

/// How often the listener looks whether the shown code ran out.
const ROTATE_EVERY: Duration = Duration::from_secs(15);

/// Replaces an expired code with a fresh one (returned for the screen); None while the code is still good or none
/// is shown.
fn rotate_expired(codes: &Mutex<CodeState>, ttl: Duration) -> Option<String> {
    let mut c = codes.lock().unwrap();
    let (_, made) = c.code.as_ref()?;
    if made.elapsed() <= ttl {
        return None;
    }
    let fresh = new_code();
    c.code = Some((fresh.clone(), Instant::now()));
    Some(fresh)
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
        let (local_for_relay, events_for_relay) = (local.clone(), events.clone());
        let codes = Arc::new(Mutex::new(CodeState::default()));
        let (c, rotate_events) = (codes.clone(), events.clone());
        let rotate = tokio::spawn(async move {
            loop {
                tokio::time::sleep(ROTATE_EVERY).await;
                if let Some(fresh) = rotate_expired(&c, CODE_TTL) {
                    let _ = rotate_events.send(Event::NewCode(fresh));
                }
            }
        });
        let c = codes.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, from)) = listener.accept().await else {
                    // Out of file descriptors and the like: wait instead of spinning.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                tokio::spawn(answer_and_report(
                    Pipe::Tcp(stream),
                    Some(from.ip()),
                    local.clone(),
                    c.clone(),
                    events.clone(),
                ));
            }
        });
        Ok(Listener {
            port,
            codes,
            local: local_for_relay,
            events: events_for_relay,
            task,
            rotate,
            bell: Mutex::new(None),
        })
    }

    /// Listens at `relay`'s doorbell too (None: the LAN only). Each ring is a session answered like a TCP connection,
    /// so codes and remembered peers work the same way across networks. Setting the same relay again changes nothing.
    pub fn set_relay(&self, relay: Option<Relay>) {
        let mut bell = self.bell.lock().unwrap();
        if bell.as_ref().map(|(r, _)| r) == relay.as_ref() {
            return;
        }
        if let Some((_, t)) = bell.take() {
            t.abort();
        }
        let Some(relay) = relay else { return };
        let (local, codes, events) = (self.local.clone(), self.codes.clone(), self.events.clone());
        let r = relay.clone();
        let task = tokio::spawn(async move {
            loop {
                match crate::relay::wait_bell(&r.web, &r.bell).await {
                    Ok(Some(session)) => match RelayPipe::answer(&r.web, &session) {
                        Ok(pipe) => {
                            let (local, codes, events) =
                                (local.clone(), codes.clone(), events.clone());
                            let (web, session) = (r.web.clone(), session.clone());
                            tokio::spawn(async move {
                                let failed = answer_and_report(
                                    Pipe::Relay(Box::new(pipe)),
                                    None,
                                    local,
                                    codes,
                                    events,
                                )
                                .await;
                                // A refused or broken session: tell the connector at once (no socket to close).
                                if failed && let Ok(mut p) = RelayPipe::answer(&web, &session) {
                                    p.close().await;
                                }
                            });
                        }
                        Err(_) => tokio::time::sleep(BELL_RETRY).await,
                    },
                    Ok(None) => {} // the host's wait ended: poll again
                    Err(_) => tokio::time::sleep(BELL_RETRY).await,
                }
            }
        });
        *bell = Some((relay, task));
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
    mut stream: Pipe,
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
    // A code's SPAKE2 answer, sent with this side's salt.
    let mut spake_reply = Vec::new();
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
            let theirs = header
                .spake
                .as_deref()
                .and_then(unhex)
                .ok_or(PairError::Protocol)?;
            let (state, msg) = spake_start(&code, true);
            spake_reply = msg;
            spake_finish(state, &theirs)?
        }
    };
    // This side's salt: a replayed recording gets another key, so it neither opens nor makes this side seal twice
    // under one key and nonce.
    let mine = random::<16>();
    write_frame(&mut stream, &[&mine[..], &spake_reply].concat()).await?;
    let mut channel = Channel::new(stream, session_key(&base, &salt, &mine), true);
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

/// The app keys after a sync, the same on both sides from one exchange: the set changed last wins whole (a key removed
/// there is removed here); at the same time the two sets fill each other's gaps. None: nothing changes here.
pub fn merge_keys(
    local: &BTreeMap<String, String>,
    local_at: i64,
    theirs: &BTreeMap<String, String>,
    their_at: i64,
) -> Option<(BTreeMap<String, String>, i64)> {
    // A side that never stamped its keys (0: they were set before keys had a time) can't win or lose whole: the two
    // sets are joined, the stamped side winning a key both have, so no key is dropped on either side.
    if local_at == 0 || their_at == 0 {
        let (first, second) = if their_at > local_at {
            (theirs, local)
        } else {
            (local, theirs)
        };
        let mut m = first.clone();
        for (k, v) in second {
            m.entry(k.clone()).or_insert_with(|| v.clone());
        }
        let at = local_at.max(their_at);
        return (m != *local || at != local_at).then_some((m, at));
    }
    let merged = if their_at > local_at {
        (theirs.clone(), their_at)
    } else if their_at < local_at {
        (local.clone(), local_at)
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
                // A newer or new profile's login, unless it is the open one's already.
                login: ((newer || added) && known.is_none_or(|p| p.login != b.login))
                    .then_some(b.login.clone()),
                incoming_login: b.login,
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
    /// A host's public front address (its relay), announced so a new device at home learns it without typing.
    pub web: Option<String>,
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

/// `web`: a host's public front address (apps pass None).
pub fn advertise(
    me: &Device,
    port: u16,
    web: Option<&str>,
) -> std::result::Result<Advertiser, String> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    let mut props = vec![
        ("id", me.id.as_str()),
        ("name", me.name.as_str()),
        ("platform", me.platform.as_str()),
    ];
    if let Some(w) = web {
        props.push(("web", w));
    }
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
                let web = Some(prop("web")).filter(|w| w.starts_with("https://"));
                found.push(Found {
                    device,
                    addr: format!("{ip}:{}", s.port),
                    web,
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
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|b| b.is_ascii_digit()));
        assert_eq!(format_code("482913"), "482 913");
        assert_eq!(normalize(&format_code(&code)), code);
        assert_eq!(normalize("oil0-1"), "01101");
        // Every digit turns up (no digit is left out by the byte mapping).
        let digits: std::collections::BTreeSet<char> = (0..200)
            .flat_map(|_| new_code().chars().collect::<Vec<_>>())
            .collect();
        assert_eq!(digits.len(), 10);
        let link = qr_text("192.0.2.7:4100", &code, None);
        assert_eq!(
            parse_pair_link(&link),
            Some(PairLink {
                addr: "192.0.2.7:4100".into(),
                code: code.clone(),
                relay: None
            })
        );
        // With a relay: its address survives the query (an `&` or `=` in it is escaped).
        let relay = Relay {
            web: "https://tv.example.invalid/a=b&c".into(),
            bell: "0123456789abcdef".into(),
        };
        let link = qr_text("192.0.2.7:4100", &code, Some(&relay));
        assert_eq!(parse_pair_link(&link).unwrap().relay, Some(relay));
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
            // Newer here: kept whole, so both sides end with the same set (the other side takes it whole).
            (m(&[("tmdb", "a")]), 20, m(&[("os", "c")]), 10, None),
            // The same time: the two fill each other's gaps.
            (
                m(&[("tmdb", "a")]),
                20,
                m(&[("os", "c")]),
                20,
                Some((m(&[("tmdb", "a"), ("os", "c")]), 20)),
            ),
            (m(&[]), 0, m(&[]), 0, None),
            // Never stamped here (keys set before they had a time): joined, the stamped side winning a shared key.
            (
                m(&[("tmdb", "a"), ("os", "x")]),
                0,
                m(&[("os", "c")]),
                30,
                Some((m(&[("tmdb", "a"), ("os", "c")]), 30)),
            ),
            (
                m(&[("os", "c")]),
                30,
                m(&[("tmdb", "a"), ("os", "x")]),
                0,
                Some((m(&[("tmdb", "a"), ("os", "c")]), 30)),
            ),
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
            None,
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
        let back = connect_peer(&addr, &phone.me, None, &peer, None)
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
            connect_peer(&addr, &device("other"), None, &stranger, None)
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
        // An older gerdTV (protocol 2: the code hashed into the key, no SPAKE2) is refused without using up the code.
        let mut old = Pipe::Tcp(TcpStream::connect(&addr).await.unwrap());
        let header = br#"{"v":2,"salt":"00000000000000000000000000000000","from":null}"#;
        write_frame(&mut old, header).await.unwrap();
        assert!(
            read_frame(&mut old).await.is_err(),
            "closed without an answer"
        );
        assert!(
            matches!(rx.recv().await.unwrap(), Event::Failed(_)),
            "a failure, not a new code"
        );
        let wrong = if code.starts_with('1') { "2" } else { "1" }.to_string() + &code[1..];
        assert!(matches!(
            connect_code(&addr, &wrong, &phone.me, None, None).await,
            Err(PairError::Auth | PairError::Io(_))
        ));
        let Event::NewCode(fresh) = rx.recv().await.unwrap() else {
            panic!("a new code first")
        };
        assert_ne!(fresh, code);
        // The old code doesn't work any more, even typed right.
        assert!(
            connect_code(&addr, &code, &phone.me, None, None)
                .await
                .is_err()
        );
        // No code at all accepted once pairing is closed.
        listener.clear_code();
        assert!(
            connect_code(&addr, &fresh, &phone.me, None, None)
                .await
                .is_err()
        );
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

    /// A sync recorded on the network and played back later gets nowhere: the listener's own salt makes another key.
    #[tokio::test]
    async fn a_replayed_sync_is_refused() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let tv = side("tv", Some("p1"), None, 100);
        let phone = side("phone", Some("p1"), Some("live:7"), 50);
        let key = hex(&random::<32>());
        let mut tv_local = tv.clone();
        tv_local.peers = vec![Peer {
            device: phone.me.clone(),
            key: key.clone(),
            addr: String::new(),
            web: String::new(),
        }];
        let (listener, _shared, mut rx) = listen(tv_local).await;
        let target = format!("127.0.0.1:{}", listener.port);
        // A relay that records what the phone sends.
        let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_addr = relay.local_addr().unwrap().to_string();
        let recorded = Arc::new(Mutex::new(Vec::<u8>::new()));
        let rec = recorded.clone();
        let t = target.clone();
        tokio::spawn(async move {
            let (mut inbound, _) = relay.accept().await.unwrap();
            let mut outbound = TcpStream::connect(&t).await.unwrap();
            let (mut ir, mut iw) = inbound.split();
            let (mut or, mut ow) = outbound.split();
            let up = async {
                let mut buf = [0u8; 4096];
                loop {
                    let n = ir.read(&mut buf).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    rec.lock().unwrap().extend_from_slice(&buf[..n]);
                    if ow.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            };
            let down = tokio::io::copy(&mut or, &mut iw);
            let _ = tokio::join!(up, down);
        });
        let peer = Peer {
            device: tv.me.clone(),
            key,
            addr: relay_addr.clone(),
            web: String::new(),
        };
        connect_peer(&relay_addr, &phone.me, None, &peer, None)
            .await
            .unwrap()
            .exchange(&phone)
            .await
            .unwrap();
        applied(&mut rx).await;
        // Played back to the listener: refused at the first sealed frame, nothing applied.
        let bytes = recorded.lock().unwrap().clone();
        let mut again = TcpStream::connect(&target).await.unwrap();
        again.write_all(&bytes).await.unwrap();
        let mut sink = Vec::new();
        let _ = again.read_to_end(&mut sink).await;
        match rx.recv().await.unwrap() {
            Event::Failed(e) => assert!(e.contains("code") || e.contains("unexpected"), "{e}"),
            other => panic!("a replay was taken: {other:?}"),
        }
        for d in [&tv.dir, &phone.dir] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }

    #[test]
    fn an_expired_code_is_replaced_by_itself() {
        let codes = Mutex::new(CodeState::default());
        assert_eq!(
            rotate_expired(&codes, Duration::ZERO),
            None,
            "no code shown"
        );
        codes.lock().unwrap().code = Some(("OLD".into(), Instant::now()));
        assert_eq!(
            rotate_expired(&codes, Duration::from_secs(600)),
            None,
            "still good"
        );
        let fresh = rotate_expired(&codes, Duration::ZERO).unwrap();
        assert_ne!(fresh, "OLD");
        assert_eq!(codes.lock().unwrap().code.as_ref().unwrap().0, fresh);
    }

    #[test]
    fn hex_has_one_spelling() {
        assert_eq!(unhex("0a"), Some(vec![10]));
        assert_eq!(unhex("0A"), None);
        assert_eq!(unhex("+a"), None);
        assert_eq!(unhex("abc"), None);
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
        // Here another profile is open: an older p1's login still isn't stored (this side may have a newer one for
        // it), but it is handed along for a side that keeps one profile (the host switching back to p1).
        let mut switched = here.clone();
        switched.secrets.profile = Some(ProfileSecrets {
            id: "p2".into(),
            ..Default::default()
        });
        let a = apply(&switched, &there.me, None, snapshot(&there).unwrap()).unwrap();
        let p = a.profile.unwrap();
        assert_eq!(p.login, None);
        assert_eq!(
            p.incoming_login,
            vec!["user-there".to_string(), "pass-there".to_string()]
        );
        for d in [&here.dir, &there.dir] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }
}
