//! Google Cast from every platform (owner decision: in the core, through oxicast, wrapped here): a channel, movie or
//! episode moves to a Cast device on the network; the phone, Mac or TV becomes the remote.
//!
//! Route (owner decision): the provider's own address first, so the sending device may sleep. Live TV goes as the
//! provider's HLS (`.m3u8`): Cast's Default Media Receiver plays HLS, not raw MPEG-TS. A movie or episode goes as its
//! file. When the receiver refuses it, or nothing plays within [START_SECS], live falls back to gerdTV's own HLS
//! (hls.rs, the same as Apple's player gets) served on the local network while casting, with a random path token and
//! the CORS header the receiver's web player needs. The provider's address carries the login: the receiver gets it
//! (owner decision, said once in the picker); it is never logged.
//! Only gerdTV's own logic here is unit-tested (owner decision: no fake receiver); casting itself is a device check.
//! Debug hints: `avahi-browse -r _googlecast._tcp` lists devices on Linux; a refused load says why in the error.

use std::net::IpAddr;
use std::time::Duration;

use oxicast::CastClient;
use oxicast::types::{CastApp, MediaInfo, MediaMetadata, PlayerState, StreamType};

/// How long a route may take to play before the next one is tried.
pub const START_SECS: u64 = 10;

#[derive(Debug, thiserror::Error)]
pub enum CastError {
    #[error("Cast: {0}")]
    Device(String),
    #[error("The Cast device didn't play it: {0}")]
    Refused(String),
}

pub type Result<T> = std::result::Result<T, CastError>;

fn device(e: impl std::fmt::Display) -> CastError {
    CastError::Device(e.to_string())
}

/// One Cast device found on the network.
#[derive(Debug, Clone, PartialEq)]
pub struct Device {
    pub name: String,
    pub ip: IpAddr,
    pub port: u16,
}

/// What a receiver is asked to play.
#[derive(Debug, Clone, PartialEq)]
pub struct Route {
    pub url: String,
    pub content_type: &'static str,
    pub live: bool,
}

/// The first route for an item: live as the provider's HLS when there is one (None: it must go through gerdTV's
/// own server), a movie or episode as its file, typed by its extension.
pub fn first_route(live: bool, provider_hls: Option<String>, file: &str) -> Option<Route> {
    if live {
        return provider_hls.map(|url| Route {
            url,
            content_type: "application/x-mpegURL",
            live: true,
        });
    }
    let path = file.split('?').next().unwrap_or(file).to_ascii_lowercase();
    let content_type = match path.rsplit('.').next() {
        Some("m3u8") => "application/x-mpegURL",
        Some("mkv") => "video/x-matroska",
        Some("webm") => "video/webm",
        Some("ts") => "video/mp2t",
        _ => "video/mp4",
    };
    Some(Route {
        url: file.to_string(),
        content_type,
        live: false,
    })
}

/// The address of this device the Cast device reaches: the interface a packet to it would leave from.
pub fn local_ip_towards(target: IpAddr) -> std::io::Result<IpAddr> {
    let any: IpAddr = if target.is_ipv4() {
        [0, 0, 0, 0].into()
    } else {
        std::net::Ipv6Addr::UNSPECIFIED.into()
    };
    let socket = std::net::UdpSocket::bind((any, 0))?;
    socket.connect((target, 9))?; // no packet is sent: connect only picks the route
    Ok(socket.local_addr()?.ip())
}

/// Devices answering on the network within `secs` (mDNS, `_googlecast._tcp`).
pub async fn discover(secs: u64) -> Result<Vec<Device>> {
    let found = oxicast::discovery::discover_devices(Duration::from_secs(secs))
        .await
        .map_err(device)?;
    let mut out: Vec<Device> = Vec::new();
    for d in found {
        if !out.iter().any(|o| o.ip == d.ip) {
            out.push(Device {
                name: d.name,
                ip: d.ip,
                port: d.port,
            });
        }
    }
    Ok(out)
}

/// A running Cast session on one device.
pub struct Session {
    client: CastClient,
}

impl Session {
    pub async fn connect(d: &Device) -> Result<Session> {
        let client = CastClient::connect(&d.ip.to_string(), d.port)
            .await
            .map_err(device)?;
        client
            .launch_app(&CastApp::DefaultMediaReceiver)
            .await
            .map_err(device)?;
        Ok(Session { client })
    }

    /// Loads `route` and waits up to [START_SECS] for it to play.
    pub async fn play(&self, route: &Route, title: &str) -> Result<()> {
        let mut media = MediaInfo::new(route.url.clone(), route.content_type);
        media.stream_type = if route.live {
            StreamType::Live
        } else {
            StreamType::Buffered
        };
        media.metadata = Some(MediaMetadata::Generic {
            title: Some(title.to_string()),
            subtitle: None,
            images: vec![],
        });
        self.client
            .load_media(&media, true, 0.0, None)
            .await
            .map_err(|e| CastError::Refused(e.to_string()))?;
        for _ in 0..START_SECS * 2 {
            if let Ok(Some(s)) = self.client.media_status().await
                && s.player_state == PlayerState::Playing
            {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        Err(CastError::Refused("it didn't start".into()))
    }

    pub async fn pause(&self, pause: bool) -> Result<()> {
        let r = if pause {
            self.client.pause().await
        } else {
            self.client.play().await
        };
        r.map(|_| ()).map_err(device)
    }

    pub async fn set_volume(&self, level: f32) -> Result<()> {
        self.client
            .set_volume(level.clamp(0.0, 1.0))
            .await
            .map(|_| ())
            .map_err(device)
    }

    /// Whether the device still plays (false: it was stopped there, or the connection is gone).
    pub async fn playing(&self) -> bool {
        matches!(
            self.client.media_status().await,
            Ok(Some(s)) if matches!(s.player_state, PlayerState::Playing | PlayerState::Buffering | PlayerState::Paused)
        )
    }

    /// Stops playing there and ends the session.
    pub async fn stop(self) {
        let _ = self.client.stop_and_close().await;
    }
}

/// A running cast; gerdTV's own HLS server (live TV's fallback route) runs as long as it does.
pub struct Casting {
    session: tokio::sync::Mutex<Option<Session>>,
    server: std::sync::Mutex<Option<crate::hls::LocalHls>>,
    /// Which route plays: "provider" or "gerdtv".
    pub route: &'static str,
}

impl Casting {
    pub async fn pause(&self, pause: bool) -> Result<()> {
        match &*self.session.lock().await {
            Some(s) => s.pause(pause).await,
            None => Ok(()),
        }
    }

    pub async fn set_volume(&self, level: f32) -> Result<()> {
        match &*self.session.lock().await {
            Some(s) => s.set_volume(level).await,
            None => Ok(()),
        }
    }

    /// False once the device stopped it (its own remote, another app) or the connection is gone.
    pub async fn playing(&self) -> bool {
        match &*self.session.lock().await {
            Some(s) => s.playing().await,
            None => false,
        }
    }

    /// Stops it on the device, closes the session and gerdTV's server.
    pub async fn stop(&self) {
        let session = self.session.lock().await.take();
        if let Some(s) = session {
            s.stop().await;
        }
        let server = self.server.lock().unwrap().take();
        if let Some(mut server) = server {
            server.stop();
        }
    }
}

/// Casts `file` (live: also the provider's HLS, if it has one) by the routes in order.
pub async fn start(
    d: &Device,
    live: bool,
    provider_hls: Option<String>,
    file: String,
    title: &str,
    user_agent: &str,
    cache_dir: &std::path::Path,
) -> Result<Casting> {
    let session = Session::connect(d).await?;
    let mut tried = None;
    if let Some(route) = first_route(live, provider_hls, &file) {
        match session.play(&route, title).await {
            Ok(()) => {
                return Ok(Casting {
                    session: tokio::sync::Mutex::new(Some(session)),
                    server: std::sync::Mutex::new(None),
                    route: "provider",
                });
            }
            Err(e) => tried = Some(e),
        }
    }
    if !live {
        session.stop().await;
        return Err(tried.unwrap_or(CastError::Refused("nothing to play".into())));
    }
    // Live: gerdTV's own HLS, on the address the device reaches (one provider connection, as for Apple's player).
    let bind = local_ip_towards(d.ip).map_err(device)?;
    let server = crate::hls::LocalHls::start_on(
        bind,
        file,
        user_agent,
        crate::hls::stream_dir(cache_dir, u64::MAX),
        0.0,
        u64::MAX,
    )
    .await
    .map_err(device)?;
    server.ready().await.map_err(device)?;
    let route = Route {
        url: server.url().to_string(),
        content_type: "application/x-mpegURL",
        live: true,
    };
    if let Err(e) = session.play(&route, title).await {
        session.stop().await;
        return Err(e);
    }
    Ok(Casting {
        session: tokio::sync::Mutex::new(Some(session)),
        server: std::sync::Mutex::new(Some(server)),
        route: "gerdtv",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// New, because nothing owns the Cast route: live takes the provider's HLS (none: gerdTV's own server), files
    /// keep their type, a query string doesn't confuse the extension.
    #[test]
    fn routes_follow_what_the_receiver_plays() {
        let hls = Some("http://p.example.invalid/live/u/p/1.m3u8".to_string());
        assert_eq!(
            first_route(true, hls.clone(), "").map(|r| (r.content_type, r.live)),
            Some(("application/x-mpegURL", true))
        );
        assert_eq!(
            first_route(true, None, "http://p.example.invalid/1.ts"),
            None
        );
        for (file, want) in [
            (
                "http://p.example.invalid/movie/u/p/9.mkv",
                "video/x-matroska",
            ),
            (
                "http://p.example.invalid/movie/u/p/9.MP4?token=1",
                "video/mp4",
            ),
            (
                "http://p.example.invalid/series/u/p/9.m3u8",
                "application/x-mpegURL",
            ),
            ("http://p.example.invalid/x", "video/mp4"),
        ] {
            let r = first_route(false, None, file).unwrap();
            assert_eq!((r.content_type, r.live), (want, false), "{file}");
        }
    }

    #[test]
    fn the_local_address_faces_the_device() {
        let ip = local_ip_towards([127, 0, 0, 1].into()).unwrap();
        assert!(ip.is_loopback());
    }
}
