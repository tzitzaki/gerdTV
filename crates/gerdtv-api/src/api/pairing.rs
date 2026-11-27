//! Bridge surface for device pairing and sync (logic: gerdtv_core::pairing). Secrets cross both ways here on purpose:
//! the app's secure storage holds them, the core seals them for the other device; nothing here logs them.

use crate::api::library::ProfileInfo;
use gerdtv_core::pairing as core;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
}

/// A remembered device; `key` is secret (stored with the other secrets).
pub struct PeerInfo {
    pub device: DeviceInfo,
    pub key: String,
    pub addr: String,
    /// A headless host's web player address ("" for apps).
    pub web: String,
}

pub struct ProfileSecretsInfo {
    pub id: String,
    pub login: Vec<String>,
    pub services: HashMap<String, String>,
}

/// This device as a sync sees it: where the profiles are, who it is, its secrets and remembered devices.
pub struct LocalInfo {
    pub dir: String,
    pub me: DeviceInfo,
    pub app_keys: HashMap<String, String>,
    pub keys_updated_at: i64,
    pub profile: Option<ProfileSecretsInfo>,
    pub peers: Vec<PeerInfo>,
    /// This device's listener port (None: not listening).
    pub port: Option<u16>,
}

/// What a sync changed here: the app stores the secrets in it and refreshes its profiles.
pub struct AppliedInfo {
    pub peer: DeviceInfo,
    /// Where the peer listens, when it said so ("ip:port").
    pub peer_addr: Option<String>,
    /// The peer's web player address, when it is a host.
    pub peer_web: Option<String>,
    /// A new pairing: remember `peer` with this key.
    pub new_key: Option<String>,
    /// The app keys to store, when they changed, and their time.
    pub app_keys: Option<HashMap<String, String>>,
    pub keys_updated_at: i64,
    pub profile: Option<AppliedProfileInfo>,
}

pub struct AppliedProfileInfo {
    pub profile: ProfileInfo,
    /// The login to store (None: unchanged).
    pub login: Option<Vec<String>>,
    /// Linked services' tokens that were missing here.
    pub services: HashMap<String, String>,
    pub added: bool,
}

/// Something the listener reports: a struct, not an enum with data (that would need the freezed package in Dart).
pub struct PairEvent {
    /// A sync finished here.
    pub applied: Option<AppliedInfo>,
    /// A sync failed: why.
    pub failed: Option<String>,
    /// Show this code instead (the old one was used or ran out); formatted.
    pub new_code: Option<String>,
}

pub struct FoundDevice {
    pub device: DeviceInfo,
    pub addr: String,
}

pub struct QrInfo {
    pub width: u32,
    /// Row by row, true = dark.
    pub modules: Vec<bool>,
}

pub struct PairLink {
    pub addr: String,
    pub code: String,
}

impl From<DeviceInfo> for core::Device {
    fn from(d: DeviceInfo) -> Self {
        core::Device {
            id: d.id,
            name: d.name,
            platform: d.platform,
        }
    }
}

impl From<core::Device> for DeviceInfo {
    fn from(d: core::Device) -> Self {
        DeviceInfo {
            id: d.id,
            name: d.name,
            platform: d.platform,
        }
    }
}

impl From<PeerInfo> for core::Peer {
    fn from(p: PeerInfo) -> Self {
        core::Peer {
            device: p.device.into(),
            key: p.key,
            addr: p.addr,
            web: p.web,
        }
    }
}

fn btree(m: HashMap<String, String>) -> BTreeMap<String, String> {
    m.into_iter().collect()
}

impl From<LocalInfo> for core::Local {
    fn from(l: LocalInfo) -> Self {
        core::Local {
            dir: PathBuf::from(l.dir),
            me: l.me.into(),
            secrets: core::LocalSecrets {
                app_keys: btree(l.app_keys),
                keys_updated_at: l.keys_updated_at,
                profile: l.profile.map(|p| core::ProfileSecrets {
                    id: p.id,
                    login: p.login,
                    services: btree(p.services),
                }),
            },
            peers: l.peers.into_iter().map(Into::into).collect(),
            port: l.port,
            web: None,
        }
    }
}

impl From<core::Applied> for AppliedInfo {
    fn from(a: core::Applied) -> Self {
        let (app_keys, keys_updated_at) = match a.app_keys {
            Some((k, t)) => (Some(k.into_iter().collect()), t),
            None => (None, 0),
        };
        AppliedInfo {
            peer: a.peer.into(),
            peer_addr: a.peer_addr,
            peer_web: a.peer_web,
            new_key: a.new_key,
            app_keys,
            keys_updated_at,
            profile: a.profile.map(|p| AppliedProfileInfo {
                profile: p.profile.into(),
                login: p.login,
                services: p.services.into_iter().collect(),
                added: p.added,
            }),
        }
    }
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// A new install's device id.
#[flutter_rust_bridge::frb(sync)]
pub fn pair_new_device_id() -> String {
    core::new_device_id()
}

/// The QR's text for this device's listener (`addr` = "ip:port") and code.
#[flutter_rust_bridge::frb(sync)]
pub fn pair_link_text(addr: String, code: String) -> String {
    core::qr_text(&addr, &core::normalize(&code))
}

/// A `gerdtv://pair?…` link (the system camera opened gerdTV with it), or None.
#[flutter_rust_bridge::frb(sync)]
pub fn pair_parse_link(link: String) -> Option<PairLink> {
    core::parse_pair_link(&link).map(|(addr, code)| PairLink { addr, code })
}

#[flutter_rust_bridge::frb(sync)]
pub fn pair_qr(text: String) -> QrInfo {
    let (width, modules) = core::qr_modules(&text);
    QrInfo {
        width: width as u32,
        modules,
    }
}

/// This device's address on the local network (the one a route to the internet would use), for the QR.
#[flutter_rust_bridge::frb(sync)]
pub fn pair_local_ip() -> Option<String> {
    core::local_ip()
}

/// A web session on a host, as its list shows it.
pub struct WebSessionInfo {
    pub id: String,
    /// Unix seconds.
    pub created: i64,
    pub expires: i64,
    /// The browser, as it named itself (shortened).
    pub agent: String,
}

/// Asks a paired host (its web address `peer.web`) for a one-time web login link; returns the link.
pub async fn host_link(me_id: String, peer: PeerInfo) -> Result<String, String> {
    let v = host_call(&me_id, peer, "link", "").await?;
    Ok(v["url"].as_str().unwrap_or("").to_string())
}

/// The host's web sessions.
pub async fn host_sessions(me_id: String, peer: PeerInfo) -> Result<Vec<WebSessionInfo>, String> {
    let v = host_call(&me_id, peer, "sessions", "").await?;
    Ok(v["sessions"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|s| WebSessionInfo {
                    id: s["id"].as_str().unwrap_or("").to_string(),
                    created: s["created"].as_i64().unwrap_or(0),
                    expires: s["expires"].as_i64().unwrap_or(0),
                    agent: s["agent"].as_str().unwrap_or("").to_string(),
                })
                .collect()
        })
        .unwrap_or_default())
}

/// Ends one of the host's web sessions.
pub async fn host_end_session(me_id: String, peer: PeerInfo, id: String) -> Result<(), String> {
    host_call(&me_id, peer, "end", &id).await.map(|_| ())
}

async fn host_call(
    me: &str,
    peer: PeerInfo,
    op: &str,
    id: &str,
) -> Result<serde_json::Value, String> {
    let web = peer.web.clone();
    let req = core::AppRequest {
        ts: core::unix_now(),
        op: op.to_string(),
        id: id.to_string(),
    };
    core::app_request(&web, me, &peer.into(), &req)
        .await
        .map_err(err)
}

/// gerdTV devices that answer on the network within `wait_ms` (mDNS; not on iOS, where the QR carries the address).
pub async fn pair_discover(me_id: String, wait_ms: u32) -> Result<Vec<FoundDevice>, String> {
    let found = tokio::task::spawn_blocking(move || {
        core::discover(&me_id, Duration::from_millis(wait_ms as u64))
    })
    .await
    .map_err(err)??;
    Ok(found
        .into_iter()
        .map(|f| FoundDevice {
            device: f.device.into(),
            addr: f.addr,
        })
        .collect())
}

/// This device listening for a pairing (with a code) and for its remembered devices' syncs.
pub struct PairListener {
    inner: core::Listener,
    local: Arc<Mutex<core::Local>>,
    events: tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<core::Event>>,
    /// The mDNS announcement (None where announcing failed or isn't wanted, e.g. iOS).
    _advertiser: Option<core::Advertiser>,
}

impl PairListener {
    /// `announce`: tell the network (mDNS); iOS passes false (it can't use multicast without an entitlement).
    pub async fn start(local: LocalInfo, announce: bool) -> Result<PairListener, String> {
        let local: core::Local = local.into();
        let me = local.me.clone();
        let local = Arc::new(Mutex::new(local));
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let inner = core::Listener::start(local.clone(), tx)
            .await
            .map_err(err)?;
        let advertiser = if announce {
            core::advertise(&me, inner.port).ok()
        } else {
            None
        };
        Ok(PairListener {
            inner,
            local,
            events: tokio::sync::Mutex::new(rx),
            _advertiser: advertiser,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn port(&self) -> u16 {
        self.inner.port
    }

    /// Accepts a new code from now on and returns it, formatted.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new_code(&self) -> String {
        core::format_code(&self.inner.new_code())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear_code(&self) {
        self.inner.clear_code()
    }

    /// The open profile, secrets or remembered devices changed.
    #[flutter_rust_bridge::frb(sync)]
    pub fn update(&self, local: LocalInfo) {
        *self.local.lock().unwrap() = local.into();
    }

    /// The next thing that happened (waits); None once stopped.
    pub async fn next_event(&self) -> Option<PairEvent> {
        let none = PairEvent {
            applied: None,
            failed: None,
            new_code: None,
        };
        Some(match self.events.lock().await.recv().await? {
            core::Event::Applied(a) => PairEvent {
                applied: Some((*a).into()),
                ..none
            },
            core::Event::Failed(e) => PairEvent {
                failed: Some(e),
                ..none
            },
            core::Event::NewCode(c) => PairEvent {
                new_code: Some(core::format_code(&c)),
                ..none
            },
        })
    }
}

/// A connection that said hello: [peer] is known, nothing was sent yet (the user confirms, then [exchange]).
pub struct PairConnection {
    inner: tokio::sync::Mutex<Option<core::Connection>>,
    peer: core::Device,
}

impl PairConnection {
    #[flutter_rust_bridge::frb(sync)]
    pub fn peer(&self) -> DeviceInfo {
        self.peer.clone().into()
    }

    /// Sends this device's bundle, takes the other's and merges it here (once).
    pub async fn exchange(&self, local: LocalInfo) -> Result<AppliedInfo, String> {
        let conn = self.inner.lock().await.take().ok_or("already sent")?;
        let local: core::Local = local.into();
        Ok(conn.exchange(&local).await.map_err(err)?.into())
    }
}

fn connection(c: core::Connection) -> PairConnection {
    PairConnection {
        peer: c.peer.clone(),
        inner: tokio::sync::Mutex::new(Some(c)),
    }
}

/// Connects with the code another device shows (typed, or from its QR).
pub async fn pair_connect_code(
    addr: String,
    code: String,
    me: DeviceInfo,
    port: Option<u16>,
) -> Result<PairConnection, String> {
    Ok(connection(
        core::connect_code(&addr, &code, &me.into(), port)
            .await
            .map_err(err)?,
    ))
}

/// Connects to a remembered device.
pub async fn pair_connect_peer(
    addr: String,
    me: DeviceInfo,
    port: Option<u16>,
    peer: PeerInfo,
) -> Result<PairConnection, String> {
    Ok(connection(
        core::connect_peer(&addr, &me.into(), port, &peer.into())
            .await
            .map_err(err)?,
    ))
}
