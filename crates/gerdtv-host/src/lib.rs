//! gerdTV's headless host (owner decision): one profile, received from a paired app (`gerdtv-host pair`), kept in
//! sync with the provider, and served to browsers as a web player. Nothing here is a cloud service: it runs on the
//! owner's own machine, reached through their own tunnel.
//!
//! Two names, one port (the tunnel sends both here; routing is by the `Host` header):
//! - the **front door** (`front`, HTTPS at the tunnel): `/l/<token>` turns a one-time login link (10 minutes) into a
//!   session and hands the browser over to the player; `/app` answers a paired app's sealed requests (a new link, the
//!   sessions, ending one; pairing.rs `app_request`).
//! - the **player** (`player`, plain HTTP, so the page may play the provider's http:// streams directly): `/h/<code>`
//!   sets the session cookie, the page itself (web/), `/api/*` for the catalogue, and `/s/<key>`, which redirects to
//!   the stream: to the provider's own redirect target where there is one (it carries a token, not the login).
//!
//! Sessions live in memory: 3 h from login, extendable by 3 h from now while still valid, ended by the app or a
//! restart. The browser never gets the login, the M3U or anything to edit them with.
//!
//! Debugging: `curl -H 'Host: <player>' http://127.0.0.1:<port>/api/session` answers 401 without a cookie; a link
//! that says "used or ran out" was opened before or is older than 10 minutes; `/s/` answering 502 means the provider
//! refused the stream (account limit, wrong login): the host's log says which.

use gerdtv_core::db::{Kind, Sort};
use gerdtv_core::library::Library;
use gerdtv_core::pairing::{
    self, AppEnvelope, Applied, Device, LocalSecrets, Peer, ProfileSecrets,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// A one-time login link works this long.
pub const LINK_TTL: i64 = 10 * 60;
/// The front door's hand-over to the player works this long (it is used at once by the redirect).
pub const HANDOFF_TTL: i64 = 60;
/// A session lasts this long from login, and an extension this long from then.
pub const SESSION_TTL: i64 = 3 * 3600;
/// Failed link or app attempts per address within [FAIL_WINDOW] before it is refused for the rest of the window.
const MAX_FAILS: u32 = 10;
const FAIL_WINDOW: i64 = 10 * 60;
/// Requests are small: the API only takes a key and a few numbers.
const MAX_BODY: usize = 64 << 10;

/// The host's settings (command line).
#[derive(Debug, Clone)]
pub struct Config {
    /// The state folder: profiles.json, the profile's database, host.json.
    pub dir: PathBuf,
    /// The front door's public address, e.g. "https://tv.example.org" (what login links point to).
    pub front: String,
    /// The player's public address, e.g. "http://watch.example.org".
    pub player: String,
    /// Where the tunnel connects to, e.g. "127.0.0.1:8790".
    pub listen: String,
    /// The tunnel's address: only its `CF-Connecting-IP` is believed (rate limits per visitor); None = the peer.
    pub proxy: Option<IpAddr>,
}

impl Config {
    fn host_of(url: &str) -> String {
        url.split("://")
            .nth(1)
            .unwrap_or(url)
            .split(['/', ':'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase()
    }
}

/// What the host keeps between runs (host.json, readable by its own user only): who it is, the profile's secrets and
/// the paired apps.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HostFile {
    pub device: Option<Device>,
    #[serde(default)]
    pub secrets: LocalSecrets,
    #[serde(default)]
    pub peers: Vec<Peer>,
}

impl HostFile {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join("host.json")
    }

    pub fn load(dir: &Path) -> std::io::Result<HostFile> {
        match std::fs::read(Self::path(dir)) {
            Ok(b) => serde_json::from_slice(&b).map_err(std::io::Error::other),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(HostFile::default()),
            Err(e) => Err(e),
        }
    }

    /// Written atomically with mode 0600: it holds the provider login and the pairing keys.
    pub fn save(&self, dir: &Path) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::create_dir_all(dir)?;
        let tmp = dir.join("host.json.tmp");
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(&serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        f.sync_all()?;
        std::fs::rename(tmp, Self::path(dir))
    }

    /// This host as paired apps see it (made once).
    pub fn device(&mut self) -> Device {
        self.device
            .get_or_insert_with(|| Device {
                id: pairing::new_device_id(),
                name: "gerdTV host".into(),
                platform: "host".into(),
            })
            .clone()
    }

    /// Stores what a sync brought (the same rules as the app's services/devices.dart): the peer, the app keys, the
    /// profile's login and services. The host keeps one profile: one that came under another id replaces it.
    pub fn store(&mut self, a: &Applied) {
        let known = self.peers.iter().position(|p| p.device.id == a.peer.id);
        if let Some(key) = &a.new_key {
            if let Some(i) = known {
                self.peers.remove(i);
            }
            self.peers.push(Peer {
                device: a.peer.clone(),
                key: key.clone(),
                addr: a.peer_addr.clone().unwrap_or_default(),
                web: String::new(),
            });
        } else if let (Some(i), Some(addr)) = (known, &a.peer_addr) {
            self.peers[i].addr = addr.clone();
        }
        if let Some((keys, at)) = &a.app_keys {
            self.secrets.app_keys = keys.clone();
            self.secrets.keys_updated_at = *at;
        }
        if let Some(p) = &a.profile {
            match &mut self.secrets.profile {
                Some(mine) if mine.id == p.profile.id => {
                    if let Some(login) = &p.login {
                        mine.login = login.clone();
                    }
                    mine.services.extend(p.services.clone());
                }
                _ => {
                    self.secrets.profile = Some(ProfileSecrets {
                        id: p.profile.id.clone(),
                        login: p.login.clone().unwrap_or_default(),
                        services: p.services.clone(),
                    })
                }
            }
        }
    }
}

// ---- logins and sessions ----

#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    pub created: i64,
    pub expires: i64,
    pub agent: String,
}

/// One-time links, hand-overs, sessions and the failure counts, all in memory.
#[derive(Default)]
pub struct Auth {
    links: HashMap<String, i64>,
    handoffs: HashMap<String, (String, i64)>,
    pub sessions: HashMap<String, Session>,
    fails: HashMap<IpAddr, (u32, i64)>,
    /// App request nonces seen within their lifetime (no replays).
    nonces: HashMap<String, i64>,
}

fn token() -> String {
    pairing::hex(&pairing::random::<16>())
}

impl Auth {
    pub fn new_link(&mut self, now: i64) -> String {
        self.links.retain(|_, made| now - *made <= LINK_TTL);
        let t = token();
        self.links.insert(t.clone(), now);
        t
    }

    /// A link opened: a new session and its hand-over code; None when used, unknown or too old.
    pub fn open_link(&mut self, t: &str, agent: &str, now: i64) -> Option<String> {
        let made = self.links.remove(t)?;
        if now - made > LINK_TTL {
            return None;
        }
        let id = token();
        self.sessions.insert(
            id.clone(),
            Session {
                created: now,
                expires: now + SESSION_TTL,
                agent: agent.chars().take(80).collect(),
            },
        );
        let code = token();
        self.handoffs.insert(code.clone(), (id, now));
        Some(code)
    }

    /// The player's half of the hand-over: the session id (once).
    pub fn take_handoff(&mut self, code: &str, now: i64) -> Option<String> {
        let (id, made) = self.handoffs.remove(code)?;
        (now - made <= HANDOFF_TTL).then_some(id)
    }

    /// A valid session (expired ones are dropped on the way).
    pub fn session(&mut self, id: &str, now: i64) -> Option<Session> {
        self.sessions.retain(|_, s| s.expires > now);
        self.sessions.get(id).cloned()
    }

    /// +3 h from now, only while still valid.
    pub fn extend(&mut self, id: &str, now: i64) -> Option<i64> {
        let s = self.sessions.get_mut(id).filter(|s| s.expires > now)?;
        s.expires = now + SESSION_TTL;
        Some(s.expires)
    }

    /// Whether `ip` is still allowed to try (a failure counts with `fail`).
    fn allowed(&mut self, ip: IpAddr, now: i64) -> bool {
        match self.fails.get(&ip) {
            Some((n, since)) if now - since <= FAIL_WINDOW => *n < MAX_FAILS,
            _ => true,
        }
    }

    fn fail(&mut self, ip: IpAddr, now: i64) {
        let e = self.fails.entry(ip).or_insert((0, now));
        if now - e.1 > FAIL_WINDOW {
            *e = (0, now);
        }
        e.0 += 1;
    }

    /// A nonce not seen within the request lifetime (and remembers it).
    fn fresh_nonce(&mut self, nonce: &str, now: i64) -> bool {
        self.nonces
            .retain(|_, seen| now - *seen <= 2 * pairing::APP_REQUEST_TTL);
        self.nonces.insert(nonce.to_string(), now).is_none()
    }
}

// ---- the shared state ----

pub struct Host {
    pub cfg: Config,
    pub file: Mutex<HostFile>,
    /// The open profile's library; replaced when a sync brings a new login.
    pub library: RwLock<Option<Arc<Library>>>,
    pub auth: Mutex<Auth>,
    http: reqwest::Client,
}

impl Host {
    pub fn new(cfg: Config, file: HostFile) -> Arc<Host> {
        gerdtv_core::xtream::ensure_tls_provider();
        let host = Arc::new(Host {
            cfg,
            file: Mutex::new(file),
            library: RwLock::new(None),
            auth: Mutex::new(Auth::default()),
            http: reqwest::Client::builder()
                // Only the provider's first answer is wanted (its redirect target), never the stream itself.
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(std::time::Duration::from_secs(10))
                .timeout(std::time::Duration::from_secs(15))
                .build()
                .expect("HTTP client"),
        });
        host.reopen();
        host
    }

    /// Opens the profile host.json names (again: after a sync changed its login).
    pub fn reopen(&self) {
        let p = self.file.lock().unwrap().secrets.profile.clone();
        let lib = p.and_then(|p| match Library::open(&self.cfg.dir, &p.id, p.login) {
            Ok(l) => Some(Arc::new(l)),
            Err(e) => {
                eprintln!("host: the profile does not open: {e}");
                None
            }
        });
        *self.library.write().unwrap() = lib;
    }

    pub fn lib(&self) -> Option<Arc<Library>> {
        self.library.read().unwrap().clone()
    }

    /// What a pairing listener needs: who this is, the secrets, the peers, the web address.
    pub fn local(&self, port: Option<u16>) -> pairing::Local {
        let mut f = self.file.lock().unwrap();
        pairing::Local {
            dir: self.cfg.dir.clone(),
            me: f.device(),
            secrets: f.secrets.clone(),
            peers: f.peers.clone(),
            port,
            web: Some(self.cfg.front.clone()),
        }
    }
}

// ---- HTTP ----

#[derive(Debug, Clone, Default)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    /// Lower-case names.
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
    pub peer: Option<IpAddr>,
}

impl Request {
    fn header(&self, name: &str) -> &str {
        self.headers.get(name).map_or("", String::as_str)
    }

    fn cookie(&self, name: &str) -> Option<&str> {
        self.header("cookie")
            .split(';')
            .filter_map(|c| c.trim().split_once('='))
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v)
    }

    fn host(&self) -> String {
        Config::host_of(&format!("x://{}", self.header("host")))
    }
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    fn new(status: u16, content_type: &'static str, body: impl Into<Vec<u8>>) -> Response {
        Response {
            status,
            content_type,
            headers: vec![],
            body: body.into(),
        }
    }

    fn json(v: Value) -> Response {
        Response::new(200, "application/json", v.to_string())
    }

    fn redirect(to: &str) -> Response {
        let mut r = Response::new(302, "text/plain", "");
        r.headers.push(("location".into(), to.into()));
        r
    }

    fn page(status: u16, text: &str) -> Response {
        Response::new(
            status,
            "text/html; charset=utf-8",
            format!(
                "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>\
                 <title>gerdTV</title><body style='font:16px system-ui;background:#111;color:#eee;padding:2em'>\
                 <h1>gerdTV</h1><p>{text}</p>"
            ),
        )
    }

    fn not_found() -> Response {
        Response::new(404, "text/plain", "not found")
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        410 => "Gone",
        429 => "Too Many Requests",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "",
    }
}

/// Serves until the process ends.
pub async fn serve(host: Arc<Host>) -> std::io::Result<()> {
    let listener = TcpListener::bind(&host.cfg.listen).await?;
    eprintln!("host: web on {}", listener.local_addr()?);
    loop {
        let (stream, peer) = listener.accept().await?;
        let host = host.clone();
        tokio::spawn(async move {
            let _ = answer(host, stream, peer.ip()).await;
        });
    }
}

async fn answer(host: Arc<Host>, mut stream: TcpStream, peer: IpAddr) -> std::io::Result<()> {
    let Some(req) = read_request(&mut stream, peer).await? else {
        return Ok(());
    };
    let res = handle(&host, req).await;
    let mut head = format!(
        "HTTP/1.1 {} {}\r\ncontent-type: {}\r\ncontent-length: {}\r\ncache-control: no-store\r\n\
         x-content-type-options: nosniff\r\nreferrer-policy: no-referrer\r\nconnection: close\r\n",
        res.status,
        reason(res.status),
        res.content_type,
        res.body.len()
    );
    for (k, v) in &res.headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&res.body).await?;
    stream.flush().await
}

async fn read_request(stream: &mut TcpStream, peer: IpAddr) -> std::io::Result<Option<Request>> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        let n = tokio::time::timeout(std::time::Duration::from_secs(15), stream.read(&mut chunk))
            .await
            .map_err(|_| std::io::Error::other("timeout"))??;
        if n == 0 {
            return Ok(None);
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        if buf.len() > 32 << 10 {
            return Ok(None);
        }
    };
    let head = String::from_utf8_lossy(&buf[..end]).to_string();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let method = first.next().unwrap_or("").to_string();
    let target = first.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let headers: HashMap<String, String> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
        .collect();
    let len: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if len > MAX_BODY {
        return Ok(None);
    }
    let mut body = buf[end + 4..].to_vec();
    while body.len() < len {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(len);
    Ok(Some(Request {
        method,
        path: decode(path),
        query: query
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (decode(k), decode(v)))
            .collect(),
        headers,
        body,
        peer: Some(peer),
    }))
}

/// Percent-decoding (`+` as a space in queries is the page's own encoding, so it stays `%20` there).
fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16)
        {
            out.push(v);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The visitor's address: the tunnel's word for it when the request came from the tunnel, else the peer's.
fn client(host: &Host, req: &Request) -> IpAddr {
    let peer = req.peer.unwrap_or(IpAddr::from([0, 0, 0, 0]));
    if host.cfg.proxy == Some(peer)
        && let Ok(ip) = req.header("cf-connecting-ip").parse()
    {
        return ip;
    }
    peer
}

/// Every request: by host name, then path.
pub async fn handle(host: &Host, req: Request) -> Response {
    let name = req.host();
    if name == Config::host_of(&host.cfg.front) {
        front(host, req).await
    } else if name == Config::host_of(&host.cfg.player) {
        player(host, req).await
    } else {
        Response::not_found()
    }
}

async fn front(host: &Host, req: Request) -> Response {
    let now = pairing::unix_now();
    let ip = client(host, &req);
    if !host.auth.lock().unwrap().allowed(ip, now) {
        return Response::page(429, "Too many attempts. Try again in a few minutes.");
    }
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/") => Response::page(
            200,
            "Open a login link from the gerdTV app: Settings → Account → Web player.",
        ),
        ("GET", p) if p.starts_with("/l/") => {
            let opened =
                host.auth
                    .lock()
                    .unwrap()
                    .open_link(&p[3..], req.header("user-agent"), now);
            match opened {
                Some(code) => Response::redirect(&format!(
                    "{}/h/{code}",
                    host.cfg.player.trim_end_matches('/')
                )),
                None => {
                    host.auth.lock().unwrap().fail(ip, now);
                    Response::page(
                        410,
                        "This link was used already or ran out. Make a new one in the gerdTV app.",
                    )
                }
            }
        }
        ("POST", "/app") => app(host, &req, ip, now),
        _ => Response::not_found(),
    }
}

/// A paired app's sealed request (pairing.rs): a new link, the sessions, or ending one.
fn app(host: &Host, req: &Request, ip: IpAddr, now: i64) -> Response {
    let refused = |host: &Host| {
        host.auth.lock().unwrap().fail(ip, now);
        Response::new(400, "text/plain", "refused")
    };
    let Ok(env) = serde_json::from_slice::<AppEnvelope>(&req.body) else {
        return refused(host);
    };
    let peers = host.file.lock().unwrap().peers.clone();
    let Some((r, nonce, key)) = pairing::open_app_request(&peers, &env) else {
        return refused(host);
    };
    let mut auth = host.auth.lock().unwrap();
    if (now - r.ts).abs() > pairing::APP_REQUEST_TTL || !auth.fresh_nonce(&env.nonce, now) {
        drop(auth);
        return refused(host);
    }
    let answer = match r.op.as_str() {
        "link" => {
            let t = auth.new_link(now);
            json!({
                "url": format!("{}/l/{t}", host.cfg.front.trim_end_matches('/')),
                "expires": now + LINK_TTL,
            })
        }
        "sessions" => {
            auth.sessions.retain(|_, s| s.expires > now);
            let list: Vec<Value> = auth
                .sessions
                .iter()
                .map(|(id, s)| {
                    json!({"id": id, "created": s.created, "expires": s.expires, "agent": s.agent})
                })
                .collect();
            json!({ "sessions": list })
        }
        "end" => json!({ "ended": auth.sessions.remove(&r.id).is_some() }),
        _ => json!({ "error": "unknown op" }),
    };
    Response::json(json!({ "sealed": pairing::seal_app_answer(&key, &nonce, &answer) }))
}

/// The page's files, compiled in (no build step; hls.js only for browsers without built-in HLS).
fn asset(path: &str) -> Option<(&'static str, &'static [u8])> {
    Some(match path {
        "/" | "/index.html" => (
            "text/html; charset=utf-8",
            include_bytes!("../web/index.html"),
        ),
        "/app.js" => ("text/javascript", include_bytes!("../web/app.js")),
        "/app.css" => ("text/css", include_bytes!("../web/app.css")),
        "/manifest.webmanifest" => (
            "application/manifest+json",
            include_bytes!("../web/manifest.webmanifest"),
        ),
        "/icon.svg" => ("image/svg+xml", include_bytes!("../web/icon.svg")),
        "/hls.min.js" => ("text/javascript", include_bytes!("../web/hls.min.js")),
        _ => return None,
    })
}

fn kind(s: &str) -> Option<Kind> {
    Some(match s {
        "live" => Kind::Live,
        "movie" => Kind::Movie,
        "series" => Kind::Series,
        _ => return None,
    })
}

fn hit(h: &gerdtv_core::db::Hit) -> Value {
    json!({"key": h.key, "name": h.name, "logo": h.logo, "number": h.number, "group": h.group})
}

fn programme(p: &Option<gerdtv_core::epg::Programme>) -> Value {
    p.as_ref().map_or(
        Value::Null,
        |p| json!({"title": p.title, "start": p.start, "stop": p.stop, "desc": p.desc}),
    )
}

async fn player(host: &Host, req: Request) -> Response {
    let now = pairing::unix_now();
    if req.method == "GET"
        && let Some((ct, body)) = asset(&req.path)
    {
        return Response::new(200, ct, body);
    }
    if let Some(code) = req.path.strip_prefix("/h/") {
        let id = host.auth.lock().unwrap().take_handoff(code, now);
        return match id {
            Some(id) => {
                let mut r = Response::redirect("/");
                r.headers.push((
                    "set-cookie".into(),
                    format!("gs={id}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}"),
                ));
                r
            }
            None => Response::redirect(&host.cfg.front),
        };
    }
    let session = req.cookie("gs").and_then(|id| {
        host.auth
            .lock()
            .unwrap()
            .session(id, now)
            .map(|s| (id.to_string(), s))
    });
    let Some((sid, session)) = session else {
        return Response::new(401, "application/json", r#"{"error":"session"}"#);
    };
    let Some(lib) = host.lib() else {
        return Response::new(503, "application/json", r#"{"error":"no profile"}"#);
    };
    match api(host, &lib, &req, &sid, &session, now).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("host: {} {}: {e}", req.method, req.path);
            Response::new(400, "application/json", json!({"error": e}).to_string())
        }
    }
}

async fn api(
    host: &Host,
    lib: &Library,
    req: &Request,
    sid: &str,
    session: &Session,
    now: i64,
) -> Result<Response, String> {
    let q = |k: &str| req.query.get(k).map_or("", String::as_str);
    let body: Value = serde_json::from_slice(&req.body).unwrap_or(Value::Null);
    let e = |e: gerdtv_core::library::LibraryError| e.to_string();
    let kinds = |k: Kind| -> Vec<Kind> {
        if k == Kind::Series {
            vec![Kind::Series]
        } else {
            vec![k]
        }
    };
    Ok(match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/api/session") => Response::json(json!({
            "profile": lib.profile().name,
            "expires": session.expires,
            "now": now,
        })),
        ("POST", "/api/extend") => {
            let expires = host.auth.lock().unwrap().extend(sid, now).ok_or("ended")?;
            let mut r = Response::json(json!({ "expires": expires }));
            r.headers.push((
                "set-cookie".into(),
                format!("gs={sid}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}"),
            ));
            r
        }
        ("GET", "/api/categories") => {
            let k = kind(q("kind")).ok_or("kind")?;
            let favs = lib.favourites(&kinds(k), Sort::Provider).map_err(e)?;
            let mut out: Vec<Value> = Vec::new();
            if !favs.is_empty() {
                out.push(json!({"id": "", "name": "★", "count": favs.len(), "favourites": true}));
            }
            for c in lib.categories(k, Sort::Provider).map_err(e)? {
                out.push(json!({"id": c.id, "name": c.name, "count": c.count}));
            }
            Response::json(Value::Array(out))
        }
        ("GET", "/api/items") => {
            let k = kind(q("kind")).ok_or("kind")?;
            let offset: usize = q("offset").parse().unwrap_or(0);
            let hits = if q("favourites") == "1" {
                lib.favourites(&kinds(k), Sort::Provider).map_err(e)?
            } else {
                lib.items(k, q("category"), Sort::Provider, 200, offset)
                    .map_err(e)?
            };
            Response::json(Value::Array(hits.iter().map(hit).collect()))
        }
        ("GET", "/api/search") => {
            let k = kind(q("kind")).ok_or("kind")?;
            let (hits, _, _) = lib.search(q("q"), &kinds(k), None, 100, 0).map_err(e)?;
            Response::json(Value::Array(hits.iter().map(hit).collect()))
        }
        ("GET", "/api/nownext") => {
            let keys: Vec<String> = q("keys")
                .split(',')
                .filter(|k| !k.is_empty())
                .take(300)
                .map(String::from)
                .collect();
            let nn = lib.now_next(&keys).map_err(e)?;
            Response::json(Value::Array(
                nn.iter()
                    .map(|(n, x)| json!({"now": programme(n), "next": programme(x)}))
                    .collect(),
            ))
        }
        ("GET", "/api/details") => {
            let d = lib.details(q("key"), None).await.map_err(e)?;
            Response::json(json!({
                "plot": d.plot, "genre": d.genre, "cast": d.cast, "director": d.director,
                "release": d.release, "duration": d.duration_secs, "rating": d.rating,
                "backdrop": d.backdrop,
                "resume": lib.resume_position(q("key")).map_err(e)?,
            }))
        }
        ("GET", "/api/episodes") => {
            let hits = lib.episodes(q("key")).await.map_err(e)?;
            Response::json(Value::Array(hits.iter().map(hit).collect()))
        }
        ("GET", "/api/continue") => {
            let rows = lib
                .continue_watching(&[Kind::Movie, Kind::Episode], 20)
                .map_err(e)?;
            Response::json(Value::Array(
                rows.iter()
                    .map(|(h, pos, dur)| {
                        let mut v = hit(h);
                        v["position"] = json!(pos);
                        v["duration"] = json!(dur);
                        v
                    })
                    .collect(),
            ))
        }
        ("GET", "/api/favkeys") => Response::json(json!(lib.favourite_keys().map_err(e)?)),
        ("POST", "/api/favourite") => {
            let key = body["key"].as_str().ok_or("key")?;
            lib.set_favourite(key, body["on"].as_bool().unwrap_or(false))
                .map_err(e)?;
            Response::json(json!({"ok": true}))
        }
        ("POST", "/api/progress") => {
            let key = body["key"].as_str().ok_or("key")?;
            let pos = body["position"].as_u64().unwrap_or(0) as u32;
            let dur = body["duration"].as_u64().unwrap_or(0) as u32;
            lib.save_progress(key, pos, dur).map_err(e)?;
            Response::json(json!({"ok": true}))
        }
        ("GET", p) if p.starts_with("/s/") => stream(host, lib, &p[3..], q("plain") == "1").await?,
        _ => Response::not_found(),
    })
}

/// The stream's address for the browser. Live goes as the provider's HLS (browsers play HLS, not raw MPEG-TS). The
/// provider usually answers with a redirect to a tokenised address: that one goes to the browser, so the login stays
/// here. A provider that serves the stream itself (no redirect) gets its plain address; one that refuses it (a dead
/// channel, the account's limit) gets a 502, so a refused stream never hands out the login. `plain` (`?plain=1`, the
/// page's retry when a tokenised address is refused, e.g. bound to this host's IP) gets the plain address instead of
/// the tokenised one, still only for a stream the provider serves.
async fn stream(host: &Host, lib: &Library, key: &str, plain: bool) -> Result<Response, String> {
    let url = lib.stream_url(key, "m3u8").map_err(|e| e.to_string())?;
    Ok(match resolve(&host.http, &url).await {
        Answer::Redirect(to) if !plain => Response::redirect(&to),
        Answer::Redirect(_) | Answer::Direct => Response::redirect(&url),
        Answer::Refused(why) => {
            eprintln!("host: the provider refused a stream: {why}");
            Response::new(502, "text/plain", "refused by the provider")
        }
    })
}

enum Answer {
    Redirect(String),
    Direct,
    Refused(String),
}

/// What the provider answers for `url` (only the head is read; the stream itself is never fetched).
async fn resolve(http: &reqwest::Client, url: &str) -> Answer {
    let res = match http.get(url).send().await {
        Ok(r) => r,
        Err(e) => return Answer::Refused(e.without_url().to_string()),
    };
    let status = res.status();
    if status.is_redirection()
        && let Some(to) = res.headers().get("location").and_then(|v| v.to_str().ok())
        // A relative target is relative to the provider's address.
        && let Some(abs) = reqwest::Url::parse(url).ok().and_then(|u| u.join(to).ok())
    {
        return Answer::Redirect(abs.to_string());
    }
    if status.is_success() {
        Answer::Direct
    } else {
        Answer::Refused(format!("HTTP {}", status.as_u16()))
    }
}
