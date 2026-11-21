//! The fault-injection stream server: plays the synthetic clip (media/) as an endless "live" MPEG-TS stream, as a
//! sliding live HLS playlist, and as a seekable VOD file, and breaks them on demand. The playback watchdog, the
//! libmpv harness, the recorder and the integration tests all run against it.
//!
//! Paths (any `<name>`, so one server can stand in for many channels):
//!   /live/<name>.ts      endless TS, paced at the clip's real-time rate (as an IPTV server sends it)
//!   /live/<name>.m3u8    live HLS: a 3-segment sliding window of 2 s segments, looping the clip with discontinuities
//!   /hls/<name>/<n>.ts   HLS segment n (with `?rotate=1` on the playlist, URLs carry a changing token: /<n>-<t>.ts)
//!   /vod/<name>.ts       the clip as a file, with Range support (seeking)
//!   /_fault/<set|once>?kind=<none|drop|stall|throttle|status|eof>&n=<bytes|code|bytes-per-s>&secs=<stall s>
//!                        injects a fault over HTTP, for tests that can't call `set`/`once` (the Flutter app's
//!                        integration tests); /_stats returns the counters as `key=value` lines
//!
//! Faults apply to requests that start after they're set: `set` keeps a fault until changed, `once` affects only the
//! next request (then the server is healthy again, which is how a reconnect is meant to succeed).
//! Debug hint: `mpv http://127.0.0.1:<port>/live/x.ts` plays it by hand; `stats()` shows what the client requested.

use crate::http::{self, Handler, Request, Server};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;

const CLIP_TS: &[u8] = include_bytes!("../media/clip.ts");
const SEGMENTS: [&[u8]; 5] = [
    include_bytes!("../media/seg0.ts"),
    include_bytes!("../media/seg1.ts"),
    include_bytes!("../media/seg2.ts"),
    include_bytes!("../media/seg3.ts"),
    include_bytes!("../media/seg4.ts"),
];
/// The clip is 10 s long; segments are 2 s each.
const CLIP_SECS: u64 = 10;
const SEGMENT_SECS: u64 = 2;
const WINDOW: u64 = 3;

/// What goes wrong for the requests that start while it is set.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Fault {
    None,
    /// Cut the connection after this many body bytes (a network drop).
    Drop {
        after_bytes: usize,
    },
    /// Stop sending after this many body bytes, keeping the connection open (a stalled server).
    Stall {
        after_bytes: usize,
        duration: Duration,
    },
    /// Send slower than real time (a congested line).
    Throttle {
        bytes_per_sec: usize,
    },
    /// Answer every request with this status and no body (5xx, 401/403 …).
    Status {
        code: u16,
    },
    /// End a live stream cleanly after this many body bytes (a live "end of file").
    LiveEof {
        after_bytes: usize,
    },
}

/// Counters for assertions (e.g. "the watchdog reconnected 3 times", "it switched from .ts to .m3u8").
#[derive(Debug, Default, Clone)]
pub struct Stats {
    pub live_ts: usize,
    pub live_hls_playlists: usize,
    pub hls_segments: usize,
    pub vod: usize,
    pub faulted: usize,
}

#[derive(Default)]
struct State {
    fault: Option<Fault>,
    once: Option<Fault>,
    stats: Stats,
}

pub struct FaultServer {
    server: Server,
    state: Arc<Mutex<State>>,
}

impl FaultServer {
    pub async fn start() -> FaultServer {
        let state = Arc::new(Mutex::new(State::default()));
        let started = Instant::now();
        let st = state.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let st = st.clone();
            Box::pin(async move { serve(req, stream, st, started).await })
        });
        FaultServer {
            server: Server::start(handler).await,
            state,
        }
    }

    pub fn url(&self, path: &str) -> String {
        self.server.url(path)
    }

    /// Keeps `fault` for every following request until changed (`Fault::None` heals the server).
    pub fn set(&self, fault: Fault) {
        self.state.lock().unwrap().fault = Some(fault);
    }

    /// Applies `fault` to the next request only.
    pub fn once(&self, fault: Fault) {
        self.state.lock().unwrap().once = Some(fault);
    }

    pub fn stats(&self) -> Stats {
        self.state.lock().unwrap().stats.clone()
    }
}

/// Takes the fault for a starting request: a pending one-shot first, else the standing one.
fn take_fault(state: &Mutex<State>) -> Fault {
    let mut s = state.lock().unwrap();
    let fault = s.once.take().or(s.fault).unwrap_or(Fault::None);
    if fault != Fault::None {
        s.stats.faulted += 1;
    }
    fault
}

/// Parses a fault from the control query (see the module docs).
pub fn parse_fault(req: &Request) -> Option<Fault> {
    let n: usize = req.param("n").and_then(|v| v.parse().ok()).unwrap_or(0);
    let secs: u64 = req.param("secs").and_then(|v| v.parse().ok()).unwrap_or(30);
    Some(match req.param("kind")? {
        "none" => Fault::None,
        "drop" => Fault::Drop { after_bytes: n },
        "stall" => Fault::Stall {
            after_bytes: n,
            duration: Duration::from_secs(secs),
        },
        "throttle" => Fault::Throttle {
            bytes_per_sec: n.max(1),
        },
        "status" => Fault::Status { code: n as u16 },
        "eof" => Fault::LiveEof { after_bytes: n },
        _ => return None,
    })
}

async fn serve(req: Request, mut stream: TcpStream, state: Arc<Mutex<State>>, started: Instant) {
    let path = req.path.clone();
    if let Some(mode) = path.strip_prefix("/_fault/") {
        let Some(fault) = parse_fault(&req) else {
            return http::respond(stream, 400, "text/plain", b"bad fault").await;
        };
        match mode {
            "set" => state.lock().unwrap().fault = Some(fault),
            "once" => state.lock().unwrap().once = Some(fault),
            _ => return http::respond(stream, 404, "text/plain", b"set or once").await,
        }
        return http::respond(stream, 200, "text/plain", format!("{fault:?}").as_bytes()).await;
    }
    if path == "/_stats" {
        let s = state.lock().unwrap().stats.clone();
        let body = format!(
            "live_ts={}\nlive_hls_playlists={}\nhls_segments={}\nvod={}\nfaulted={}\n",
            s.live_ts, s.live_hls_playlists, s.hls_segments, s.vod, s.faulted
        );
        return http::respond(stream, 200, "text/plain", body.as_bytes()).await;
    }
    let kind = if path.starts_with("/live/") && path.ends_with(".ts") {
        "live_ts"
    } else if path.starts_with("/live/") && path.ends_with(".m3u8") {
        "playlist"
    } else if path.starts_with("/hls/") {
        "segment"
    } else if path.starts_with("/vod/") {
        "vod"
    } else {
        return http::respond(stream, 404, "text/plain", b"not found").await;
    };
    {
        let mut s = state.lock().unwrap();
        match kind {
            "live_ts" => s.stats.live_ts += 1,
            "playlist" => s.stats.live_hls_playlists += 1,
            "segment" => s.stats.hls_segments += 1,
            _ => s.stats.vod += 1,
        }
    }
    let fault = take_fault(&state);
    if let Fault::Status { code } = fault {
        return http::respond(stream, code, "text/plain", b"").await;
    }
    match kind {
        "live_ts" => {
            if http::write_head(&mut stream, 200, "video/mp2t", None)
                .await
                .is_ok()
            {
                // Real time: the clip's bytes per second; the first second goes out at once, as live servers do.
                let rate = CLIP_TS.len() / CLIP_SECS as usize;
                let looped = CLIP_TS.iter().copied().cycle();
                send_paced(&mut stream, looped, None, rate, rate, fault).await;
            }
        }
        "playlist" => {
            let rotate = req.param("rotate") == Some("1");
            let name = path.trim_start_matches("/live/").trim_end_matches(".m3u8");
            let body = hls_playlist(name, started.elapsed(), rotate);
            http::respond(
                stream,
                200,
                "application/vnd.apple.mpegurl",
                body.as_bytes(),
            )
            .await;
        }
        "segment" => {
            // /hls/<name>/<n>.ts or /hls/<name>/<n>-<token>.ts
            let file = path.rsplit('/').next().unwrap_or("");
            let n: u64 = file
                .trim_end_matches(".ts")
                .split('-')
                .next()
                .unwrap_or("")
                .parse()
                .unwrap_or(u64::MAX);
            if n == u64::MAX {
                return http::respond(stream, 404, "text/plain", b"bad segment").await;
            }
            let seg = SEGMENTS[(n % SEGMENTS.len() as u64) as usize];
            if http::write_head(&mut stream, 200, "video/mp2t", Some(seg.len()))
                .await
                .is_ok()
            {
                send_paced(
                    &mut stream,
                    seg.iter().copied(),
                    Some(seg.len()),
                    usize::MAX,
                    0,
                    fault,
                )
                .await;
            }
        }
        _ => serve_vod(req, stream, fault).await,
    }
}

/// The live HLS playlist at time `elapsed`: segment n becomes available at n × 2 s; the window holds the last 3.
/// Each clip loop starts with EXT-X-DISCONTINUITY (timestamps restart); the discontinuity sequence counts the loops
/// before the window's first segment, so a client can follow the sliding window without losing its place.
pub fn hls_playlist(name: &str, elapsed: Duration, rotate: bool) -> String {
    let newest = elapsed.as_secs() / SEGMENT_SECS + WINDOW - 1; // a full window is available from the start
    let first = newest + 1 - WINDOW;
    let per_loop = SEGMENTS.len() as u64;
    let mut out = format!(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:{SEGMENT_SECS}\n#EXT-X-MEDIA-SEQUENCE:{first}\n#EXT-X-DISCONTINUITY-SEQUENCE:{}\n",
        first / per_loop
    );
    for n in first..=newest {
        if n % per_loop == 0 && n != first {
            out.push_str("#EXT-X-DISCONTINUITY\n");
        }
        // Rotating URLs stand in for providers that sign segment URLs per playlist refresh.
        let token = if rotate {
            format!("-{}", elapsed.as_millis())
        } else {
            String::new()
        };
        out.push_str(&format!(
            "#EXTINF:{SEGMENT_SECS}.0,\n/hls/{name}/{n}{token}.ts\n"
        ));
    }
    out
}

async fn serve_vod(req: Request, mut stream: TcpStream, fault: Fault) {
    let total = CLIP_TS.len();
    // Only the "bytes=<start>-" and "bytes=<start>-<end>" forms; that's what FFmpeg sends when seeking.
    let range = req
        .header("range")
        .and_then(|r| r.strip_prefix("bytes="))
        .and_then(|r| {
            let (a, b) = r.split_once('-')?;
            let start: usize = a.parse().ok()?;
            let end: usize = if b.is_empty() {
                total - 1
            } else {
                b.parse().ok()?
            };
            (start <= end && end < total).then_some((start, end))
        });
    let (status, start, end) = match range {
        Some((s, e)) => (206, s, e),
        None => (200, 0, total - 1),
    };
    let body = &CLIP_TS[start..=end];
    let mut head = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: video/mp2t\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    if status == 206 {
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    }
    head.push_str("\r\n");
    if stream.write_all(head.as_bytes()).await.is_ok() {
        send_paced(
            &mut stream,
            body.iter().copied(),
            Some(body.len()),
            usize::MAX,
            0,
            fault,
        )
        .await;
    }
}

/// Sends `bytes` (possibly endless) at `rate` bytes/s after an initial `burst`, applying the fault.
/// `rate == usize::MAX` means as fast as the socket takes it. Stops when the client goes away.
async fn send_paced(
    stream: &mut TcpStream,
    bytes: impl Iterator<Item = u8>,
    len: Option<usize>,
    rate: usize,
    burst: usize,
    fault: Fault,
) {
    // A congested line has no start-up burst either.
    let (rate, burst) = match fault {
        Fault::Throttle { bytes_per_sec } => (bytes_per_sec.min(rate), 0),
        _ => (rate, burst),
    };
    let chunk_size = 188 * 32; // whole TS packets
    let mut sent = 0usize;
    let started = Instant::now();
    let mut stalled = false;
    let mut chunk = Vec::with_capacity(chunk_size);
    let mut bytes = bytes.peekable();
    while bytes.peek().is_some() {
        chunk.clear();
        chunk.extend(bytes.by_ref().take(chunk_size));
        match fault {
            Fault::Drop { after_bytes } if sent >= after_bytes => return, // dropping the stream closes the socket
            Fault::LiveEof { after_bytes } if sent >= after_bytes => {
                let _ = stream.shutdown().await;
                return;
            }
            Fault::Stall {
                after_bytes,
                duration,
            } if sent >= after_bytes && !stalled => {
                stalled = true;
                tokio::time::sleep(duration).await;
            }
            _ => {}
        }
        if stream.write_all(&chunk).await.is_err() {
            return;
        }
        sent += chunk.len();
        if rate != usize::MAX && sent > burst {
            // Sleep until the paced schedule catches up with what was sent.
            let due = Duration::from_secs_f64((sent - burst) as f64 / rate as f64);
            if let Some(wait) = due.checked_sub(started.elapsed()) {
                tokio::time::sleep(wait).await;
            }
        }
    }
    let _ = len; // the length was already announced in the head; nothing more to do
    let _ = stream.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hls_window_slides_and_counts_loops() {
        let p = hls_playlist("x", Duration::from_secs(0), false);
        assert!(p.contains("#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-DISCONTINUITY-SEQUENCE:0"));
        assert!(
            p.contains("/hls/x/0.ts") && p.contains("/hls/x/2.ts") && !p.contains("/hls/x/3.ts")
        );
        // At 8 s the window is segments 4, 5, 6; segment 5 starts the second loop.
        let p = hls_playlist("x", Duration::from_secs(8), false);
        assert!(p.contains("#EXT-X-MEDIA-SEQUENCE:4\n#EXT-X-DISCONTINUITY-SEQUENCE:0"));
        assert!(p.contains("#EXT-X-DISCONTINUITY\n#EXTINF:2.0,\n/hls/x/5.ts"));
        // At 10 s the first segment (5) is itself the loop start: no tag, the sequence moves on instead.
        let p = hls_playlist("x", Duration::from_secs(10), false);
        assert!(p.contains("#EXT-X-MEDIA-SEQUENCE:5\n#EXT-X-DISCONTINUITY-SEQUENCE:1"));
        assert!(!p.contains("#EXT-X-DISCONTINUITY\n"));
        assert!(hls_playlist("x", Duration::from_millis(1234), true).contains("/hls/x/0-1234.ts"));
    }
}
