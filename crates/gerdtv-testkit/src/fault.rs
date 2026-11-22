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
//!                        integration tests); /_fault/cut closes every open stream (see `cut`);
//!                        /_stats returns the counters as `key=value` lines
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

// ---- an endless live TS with continuous timestamps ----
//
// Looping the clip's bytes as they are would restart its timestamps every 10 s; mpv then sees a discontinuity per
// loop (positions jump back, the cache never holds more than one loop). A real channel's timestamps keep counting,
// so on each loop n the PTS/DTS of every PES header and the PCR of every adaptation field are shifted by n × the
// clip's span, and continuity counters run on per PID.

const TS: usize = 188;
const PTS_WRAP: u64 = 1 << 33;

/// Reads a 5-byte PES timestamp (33 bits with marker bits).
fn read_ts(b: &[u8]) -> u64 {
    (((b[0] as u64 >> 1) & 0x07) << 30)
        | ((b[1] as u64) << 22)
        | (((b[2] as u64) >> 1) << 15)
        | ((b[3] as u64) << 7)
        | ((b[4] as u64) >> 1)
}

/// Writes a 5-byte PES timestamp, keeping the 4-bit prefix of the original first byte.
fn write_ts(b: &mut [u8], v: u64) {
    let v = v % PTS_WRAP;
    b[0] = (b[0] & 0xf0) | (((v >> 30) as u8 & 0x07) << 1) | 1;
    b[1] = (v >> 22) as u8;
    b[2] = (((v >> 15) as u8) << 1) | 1;
    b[3] = (v >> 7) as u8;
    b[4] = ((v as u8) << 1) | 1;
}

/// Where a packet's payload starts, and whether it has a PCR (offset 6..12) — None for malformed packets.
fn layout(p: &[u8]) -> Option<(usize, bool)> {
    if p.len() != TS || p[0] != 0x47 {
        return None;
    }
    let afc = (p[3] >> 4) & 3;
    let (start, pcr) = if afc & 2 != 0 {
        let len = p[4] as usize;
        (5 + len, len > 0 && p[5] & 0x10 != 0)
    } else {
        (4, false)
    };
    (start <= TS).then_some((start, pcr))
}

/// Visits each PES timestamp field (PTS, DTS) of a packet that starts a PES packet: (byte offset in the packet).
fn pes_timestamps(p: &[u8]) -> Vec<usize> {
    let Some((start, _)) = layout(p) else {
        return vec![];
    };
    let pusi = p[1] & 0x40 != 0;
    let q = &p[start..];
    if !pusi || q.len() < 19 || q[..3] != [0, 0, 1] || !(0xc0..=0xef).contains(&q[3]) {
        return vec![];
    }
    match q[7] >> 6 {
        2 => vec![start + 9],
        3 => vec![start + 9, start + 14],
        _ => vec![],
    }
}

/// The clip's timestamp span: from its first to just past its last PES timestamp (one video frame, 40 ms).
fn clip_span(clip: &[u8]) -> u64 {
    let (mut lo, mut hi) = (u64::MAX, 0);
    for p in clip.as_chunks::<TS>().0 {
        for off in pes_timestamps(p) {
            let t = read_ts(&p[off..off + 5]);
            lo = lo.min(t);
            hi = hi.max(t);
        }
    }
    hi - lo + 3600
}

/// The live stream: the clip forever, loop n shifted by n × span, continuity counters continuous per PID.
pub struct LiveTs {
    span: u64,
    index: usize,
    loops: u64,
    cc: std::collections::HashMap<u16, u8>,
}

impl LiveTs {
    pub fn new() -> LiveTs {
        LiveTs {
            span: clip_span(CLIP_TS),
            index: 0,
            loops: 0,
            cc: Default::default(),
        }
    }

    /// The next 188-byte packet.
    pub fn next_packet(&mut self) -> [u8; TS] {
        let packets = CLIP_TS.len() / TS;
        if self.index == packets {
            self.index = 0;
            self.loops += 1;
        }
        let mut p = [0u8; TS];
        p.copy_from_slice(&CLIP_TS[self.index * TS..(self.index + 1) * TS]);
        self.index += 1;
        let shift = self.loops * self.span;
        if shift > 0 {
            for off in pes_timestamps(&p) {
                let t = read_ts(&p[off..off + 5]);
                write_ts(&mut p[off..off + 5], t + shift);
            }
            if let Some((_, true)) = layout(&p) {
                // PCR base: 33 bits in bytes 6..10 plus the top bit of byte 10.
                let base = ((p[6] as u64) << 25)
                    | ((p[7] as u64) << 17)
                    | ((p[8] as u64) << 9)
                    | ((p[9] as u64) << 1)
                    | ((p[10] as u64) >> 7);
                let b = (base + shift) % PTS_WRAP;
                p[6] = (b >> 25) as u8;
                p[7] = (b >> 17) as u8;
                p[8] = (b >> 9) as u8;
                p[9] = (b >> 1) as u8;
                p[10] = (p[10] & 0x7f) | (((b & 1) as u8) << 7);
            }
        }
        // Continuity counters: count on per PID across loops (only packets with payload advance them).
        let pid = (((p[1] & 0x1f) as u16) << 8) | p[2] as u16;
        if (p[3] >> 4) & 1 != 0 {
            let cc = self.cc.entry(pid).or_insert(p[3] & 0x0f);
            p[3] = (p[3] & 0xf0) | *cc;
            *cc = (*cc + 1) & 0x0f;
        }
        p
    }
}

impl Default for LiveTs {
    fn default() -> Self {
        Self::new()
    }
}

impl LiveTs {
    /// The stream as an endless byte iterator (what the paced sender consumes).
    pub fn bytes(mut self) -> impl Iterator<Item = u8> {
        std::iter::from_fn(move || Some(self.next_packet())).flat_map(|p| p.into_iter())
    }
}

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
    /// Bumped by `cut`; a stream that started under an older generation stops at its next chunk.
    generation: u64,
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

    /// Closes every stream that is open right now (a drop that hits a client mid-playback; new requests then get
    /// whatever fault is set).
    pub fn cut(&self) {
        self.state.lock().unwrap().generation += 1;
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
    if path == "/_fault/cut" {
        state.lock().unwrap().generation += 1;
        return http::respond(stream, 200, "text/plain", b"cut").await;
    }
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
                send_paced(
                    &mut stream,
                    LiveTs::new().bytes(),
                    None,
                    rate,
                    rate,
                    fault,
                    &state,
                )
                .await;
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
                    &state,
                )
                .await;
            }
        }
        _ => serve_vod(req, stream, fault, &state).await,
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

async fn serve_vod(req: Request, mut stream: TcpStream, fault: Fault, state: &Mutex<State>) {
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
            state,
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
    state: &Mutex<State>,
) {
    let generation = state.lock().unwrap().generation;
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
        if state.lock().unwrap().generation != generation {
            return; // cut: dropping the stream closes the socket
        }
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
    fn live_ts_timestamps_keep_counting_across_loops() {
        assert_eq!(
            read_ts(&{
                let mut b = [0x21, 0, 1, 0, 1];
                write_ts(&mut b, 123_456_789);
                b
            }),
            123_456_789
        );
        let span = clip_span(CLIP_TS);
        assert!(
            (900_000..910_000).contains(&span),
            "about 10 s at 90 kHz: {span}"
        );
        let packets = CLIP_TS.len() / TS;
        let mut live = LiveTs::new();
        let first: Vec<[u8; TS]> = (0..packets).map(|_| live.next_packet()).collect();
        let second: Vec<[u8; TS]> = (0..packets).map(|_| live.next_packet()).collect();
        // Every PES timestamp of loop 2 is loop 1's plus the span.
        let mut checked = 0;
        for (a, b) in first.iter().zip(&second) {
            for off in pes_timestamps(a) {
                assert_eq!(read_ts(&b[off..off + 5]), read_ts(&a[off..off + 5]) + span);
                checked += 1;
            }
        }
        assert!(
            checked > 250,
            "video (250 frames) and audio PES headers seen: {checked}"
        );
        // Continuity counters run on per PID across the loop point.
        let pid = |p: &[u8; TS]| (((p[1] & 0x1f) as u16) << 8) | p[2] as u16;
        let last_of = |pid_: u16| {
            first
                .iter()
                .rev()
                .find(|p| pid(p) == pid_ && (p[3] >> 4) & 1 != 0)
                .unwrap()[3]
                & 0x0f
        };
        let next_of = |pid_: u16| {
            second
                .iter()
                .find(|p| pid(p) == pid_ && (p[3] >> 4) & 1 != 0)
                .unwrap()[3]
                & 0x0f
        };
        let video = pid(first
            .iter()
            .find(|p| !pes_timestamps(&p[..]).is_empty())
            .unwrap());
        assert_eq!(next_of(video), (last_of(video) + 1) & 0x0f);
    }

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
