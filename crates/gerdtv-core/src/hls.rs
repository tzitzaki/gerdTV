//! Local HLS for live channels on Apple platforms (owner decision: live plays in AVPlayer, fed by the core).
//!
//! AVPlayer can't play a raw MPEG-TS stream and only rewinds inside the provider's own HLS window (often ~30 s). So
//! the core holds the one provider connection itself: it reads the live TS, cuts it into ~2 s segments at keyframes
//! ([Segmenter]), keeps them on disk for the timeshift window ([Window]) and serves a growing live playlist on
//! 127.0.0.1 ([LocalHls]). AVPlayer pauses and rewinds across the whole window; a provider drop or stall is
//! reconnected here and shows to AVPlayer only as an `#EXT-X-DISCONTINUITY`.
//!
//! Debugging: `curl http://127.0.0.1:<port>/<token>/index.m3u8` shows the playlist (the URL is in the app's log as
//! "local HLS on …"); `ffprobe` on a segment file in the cache folder shows its streams. The upstream URL carries the
//! login and is never logged.

use std::collections::VecDeque;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// A segment is cut at the first keyframe this long after its start. Short segments start AVPlayer sooner (it
/// begins about three segments before the live edge); IPTV keyframes come every 1–2 s, some every 5 s.
pub const SEGMENT_SECS: f64 = 2.0;
/// No upstream bytes for this long: the connection is dead, reconnect.
pub const STALL_SECS: u64 = 10;
/// Longest wait between reconnect attempts (1, 2, 4, 8, 10, 10 … s).
const MAX_BACKOFF_SECS: u64 = 10;
/// Timestamps jumping by more than this (backwards or forwards) mean the provider restarted its encoder.
const JUMP_SECS: f64 = 10.0;
const PTS_HZ: f64 = 90_000.0;
const PTS_MASK: u64 = (1 << 33) - 1;
const TS: usize = 188;

/// One cut segment: whole TS packets, starting with PAT and PMT and a keyframe.
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    pub data: Vec<u8>,
    pub secs: f64,
    /// The stream before it was cut off or its timestamps jumped: the player must reset its decoder.
    pub discontinuity: bool,
}

/// Cuts an MPEG-TS byte stream into HLS segments at keyframes. Feed it any chunk sizes.
#[derive(Default)]
pub struct Segmenter {
    carry: Vec<u8>,
    pmt_pid: Option<u16>,
    pat: Option<Vec<u8>>,
    pmt: Option<Vec<u8>>,
    /// The PID whose PES timestamps time the segments (the video, else the first stream), and its stream type.
    clock: Option<(u16, u8)>,
    current: Vec<u8>,
    start_pts: Option<u64>,
    last_pts: Option<u64>,
    discontinuity: bool,
}

impl Segmenter {
    pub fn new() -> Segmenter {
        Segmenter::default()
    }

    /// After a reconnect: the partial segment is dropped, the tables are read again (the new connection may differ)
    /// and the next segment is marked as a discontinuity.
    pub fn reset(&mut self) {
        *self = Segmenter {
            discontinuity: true,
            ..Segmenter::default()
        };
    }

    /// Adds bytes; returns the segments completed by them.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Segment> {
        self.carry.extend_from_slice(bytes);
        let mut out = Vec::new();
        let mut i = 0;
        while self.carry.len() - i >= TS {
            if self.carry[i] != 0x47 {
                i += 1; // lost sync: skip to the next sync byte
                continue;
            }
            let packet: [u8; TS] = self.carry[i..i + TS].try_into().unwrap();
            if let Some(seg) = self.packet(&packet) {
                out.push(seg);
            }
            i += TS;
        }
        self.carry.drain(..i);
        out
    }

    fn packet(&mut self, p: &[u8; TS]) -> Option<Segment> {
        let pid = ((p[1] as u16 & 0x1f) << 8) | p[2] as u16;
        let start = p[1] & 0x40 != 0;
        let afc = (p[3] >> 4) & 3;
        let mut off = 4;
        let mut random_access = false;
        if afc & 2 != 0 {
            let len = p[4] as usize;
            random_access = len > 0 && p[5] & 0x40 != 0;
            off = 5 + len;
        }
        let payload: &[u8] = if afc & 1 != 0 && off < TS {
            &p[off..]
        } else {
            &[]
        };

        if start && pid == 0 {
            self.pmt_pid = pat_pmt_pid(payload);
            self.pat = Some(p.to_vec());
        } else if start
            && Some(pid) == self.pmt_pid
            && let Some(clock) = pmt_clock(payload)
        {
            self.clock = Some(clock);
            self.pmt = Some(p.to_vec());
        }

        let mut cut = None;
        if let (true, Some((clock_pid, stream_type))) = (start, self.clock)
            && pid == clock_pid
            && let Some(pts) = pes_pts(payload)
        {
            cut = self.on_pes(pts, stream_type, random_access, payload);
        }
        if self.start_pts.is_some() {
            self.current.extend_from_slice(p);
        }
        cut
    }

    /// A PES of the clock stream begins: maybe close the segment and start the next one here.
    fn on_pes(
        &mut self,
        pts: u64,
        stream_type: u8,
        random_access: bool,
        payload: &[u8],
    ) -> Option<Segment> {
        let last = self.last_pts.replace(pts);
        let jumped = last.is_some_and(|l| {
            let ahead = pts.wrapping_sub(l) & PTS_MASK;
            let behind = l.wrapping_sub(pts) & PTS_MASK;
            ahead.min(behind) as f64 / PTS_HZ > JUMP_SECS
        });
        if jumped {
            // The old timeline ends here; the next keyframe starts a new one.
            let seg = self.finish(last.unwrap());
            self.discontinuity = true;
            self.start_pts = None;
            if !is_keyframe(stream_type, random_access, payload) {
                return seg;
            }
            self.begin(pts);
            return seg;
        }
        if !is_keyframe(stream_type, random_access, payload) {
            return None;
        }
        match self.start_pts {
            None => {
                self.begin(pts);
                None
            }
            Some(s) if (pts.wrapping_sub(s) & PTS_MASK) as f64 / PTS_HZ >= SEGMENT_SECS => {
                let seg = self.finish(pts);
                self.begin(pts);
                seg
            }
            Some(_) => None,
        }
    }

    fn begin(&mut self, pts: u64) {
        self.current.clear();
        if let (Some(pat), Some(pmt)) = (&self.pat, &self.pmt) {
            self.current.extend_from_slice(pat);
            self.current.extend_from_slice(pmt);
        }
        self.start_pts = Some(pts);
    }

    /// The running segment, ending at `end_pts`.
    fn finish(&mut self, end_pts: u64) -> Option<Segment> {
        let start = self.start_pts?;
        let secs = (end_pts.wrapping_sub(start) & PTS_MASK) as f64 / PTS_HZ;
        let data = std::mem::take(&mut self.current);
        (secs > 0.0 && !data.is_empty()).then(|| Segment {
            data,
            secs,
            discontinuity: std::mem::take(&mut self.discontinuity),
        })
    }
}

/// The first programme's PMT PID from a PAT section.
fn pat_pmt_pid(payload: &[u8]) -> Option<u16> {
    let s = payload.get(1 + *payload.first()? as usize..)?;
    let len = (((*s.get(1)? as usize) & 0x0f) << 8) | *s.get(2)? as usize;
    let programs = s.get(8..(3 + len).saturating_sub(4))?;
    programs
        .as_chunks::<4>()
        .0
        .iter()
        .find(|e| u16::from_be_bytes([e[0], e[1]]) != 0)
        .map(|e| ((e[2] as u16 & 0x1f) << 8) | e[3] as u16)
}

/// The clock stream from a PMT section: the first video stream, else the first stream.
fn pmt_clock(payload: &[u8]) -> Option<(u16, u8)> {
    let s = payload.get(1 + *payload.first()? as usize..)?;
    let len = (((*s.get(1)? as usize) & 0x0f) << 8) | *s.get(2)? as usize;
    let info = (((*s.get(10)? as usize) & 0x0f) << 8) | *s.get(11)? as usize;
    let mut rest = s.get(12 + info..(3 + len).saturating_sub(4))?;
    let mut first = None;
    while rest.len() >= 5 {
        let (kind, pid) = (rest[0], ((rest[1] as u16 & 0x1f) << 8) | rest[2] as u16);
        if matches!(kind, 0x01 | 0x02 | 0x1b | 0x24) {
            return Some((pid, kind));
        }
        first.get_or_insert((pid, kind));
        let es = (((rest[3] as usize) & 0x0f) << 8) | rest[4] as usize;
        rest = rest.get(5 + es..)?;
    }
    first
}

/// A PES header's PTS (90 kHz).
fn pes_pts(p: &[u8]) -> Option<u64> {
    if p.len() < 14 || p[..3] != [0, 0, 1] || p[7] & 0x80 == 0 {
        return None;
    }
    let b = &p[9..14];
    Some(
        ((b[0] as u64 >> 1) & 0x07) << 30
            | (b[1] as u64) << 22
            | ((b[2] as u64) >> 1) << 15
            | (b[3] as u64) << 7
            | (b[4] as u64) >> 1,
    )
}

/// Whether this PES starts a keyframe: the TS random-access flag, else a key picture in the first packet's payload
/// (H.264 IDR, HEVC IRAP, an MPEG-2 sequence header). Audio-only streams can cut at every PES.
fn is_keyframe(stream_type: u8, random_access: bool, payload: &[u8]) -> bool {
    if random_access || !matches!(stream_type, 0x01 | 0x02 | 0x1b | 0x24) {
        return true;
    }
    let es = payload
        .get(9 + *payload.get(8).unwrap_or(&0) as usize..)
        .unwrap_or(&[]);
    es.windows(4).any(|w| {
        w[..3] == [0, 0, 1]
            && match stream_type {
                0x1b => w[3] & 0x1f == 5,
                0x24 => (16..=21).contains(&((w[3] >> 1) & 0x3f)),
                _ => w[3] == 0xb3,
            }
    })
}

/// The segments on disk for the timeshift window, and the playlist over them.
pub struct Window {
    dir: PathBuf,
    max_secs: f64,
    max_bytes: u64,
    entries: VecDeque<Entry>,
    next_seq: u64,
    /// Discontinuities that left the window (EXT-X-DISCONTINUITY-SEQUENCE).
    discontinuity_seq: u64,
    secs: f64,
    bytes: u64,
}

struct Entry {
    seq: u64,
    secs: f64,
    bytes: u64,
    discontinuity: bool,
}

/// Always kept, whatever the budget: AVPlayer needs a few segments to start.
const MIN_SEGMENTS: usize = 3;

impl Window {
    pub fn new(dir: PathBuf, max_secs: f64, max_bytes: u64) -> io::Result<Window> {
        std::fs::create_dir_all(&dir)?;
        Ok(Window {
            dir,
            max_secs,
            max_bytes,
            entries: VecDeque::new(),
            next_seq: 0,
            discontinuity_seq: 0,
            secs: 0.0,
            bytes: 0,
        })
    }

    /// Writes the segment and drops the oldest ones beyond the budget (seconds and bytes).
    pub fn add(&mut self, seg: &Segment) -> io::Result<()> {
        let seq = self.next_seq;
        std::fs::write(self.file(seq), &seg.data)?;
        self.next_seq += 1;
        self.entries.push_back(Entry {
            seq,
            secs: seg.secs,
            bytes: seg.data.len() as u64,
            discontinuity: seg.discontinuity,
        });
        self.secs += seg.secs;
        self.bytes += seg.data.len() as u64;
        while self.entries.len() > MIN_SEGMENTS
            && (self.secs > self.max_secs || self.bytes > self.max_bytes)
        {
            let old = self.entries.pop_front().unwrap();
            let _ = std::fs::remove_file(self.file(old.seq));
            self.secs -= old.secs;
            self.bytes -= old.bytes;
            if old.discontinuity {
                self.discontinuity_seq += 1;
            }
        }
        Ok(())
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Seconds in the window (what AVPlayer can rewind).
    pub fn secs(&self) -> f64 {
        self.secs
    }

    fn file(&self, seq: u64) -> PathBuf {
        self.dir.join(format!("{seq}.ts"))
    }

    /// A segment's bytes, if it is still in the window.
    pub fn segment(&self, seq: u64) -> Option<Vec<u8>> {
        self.entries
            .iter()
            .any(|e| e.seq == seq)
            .then(|| std::fs::read(self.file(seq)).ok())?
    }

    /// The live playlist (no end tag: it keeps growing; segments are named by sequence number).
    pub fn playlist(&self) -> String {
        let target = self
            .entries
            .iter()
            .map(|e| e.secs.ceil() as u64)
            .max()
            .unwrap_or(SEGMENT_SECS as u64);
        let first = self.entries.front().map_or(self.next_seq, |e| e.seq);
        let mut m = format!(
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:{target}\n#EXT-X-MEDIA-SEQUENCE:{first}\n\
             #EXT-X-DISCONTINUITY-SEQUENCE:{}\n",
            self.discontinuity_seq
        );
        for e in &self.entries {
            if e.discontinuity {
                m.push_str("#EXT-X-DISCONTINUITY\n");
            }
            m.push_str(&format!("#EXTINF:{:.3},\n{}.ts\n", e.secs, e.seq));
        }
        m
    }
}

/// What the app shows about the local HLS (polled once a second).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Status {
    /// Seconds in the timeshift window.
    pub window_secs: f64,
    /// Reconnects to the provider so far.
    pub reconnects: u32,
    /// Reconnecting right now (no data for a while, or the provider answered an error).
    pub reconnecting: bool,
    /// The provider refused the stream (HTTP status); retrying stopped.
    pub refused: Option<u16>,
}

/// The message the player shows when the provider refused the stream (the watchdog's wording for mpv).
pub fn refusal_message(code: u16) -> String {
    match crate::playback::hard_error(&format!("http error {code}")) {
        Some(m) => m.to_string(),
        None => "The provider doesn't offer this channel (any more).".to_string(),
    }
}

struct Shared {
    window: Window,
    status: Status,
}

/// A running local HLS: the provider connection, the segments and the server. Stops (and deletes its segments) on
/// [LocalHls::stop] or when dropped.
pub struct LocalHls {
    url: String,
    shared: Arc<Mutex<Shared>>,
    dir: PathBuf,
    tasks: Vec<tokio::task::AbortHandle>,
}

impl LocalHls {
    /// Starts reading `upstream` (with the profile's user agent) and serving it; returns once the server listens.
    /// `dir` is this stream's own folder in the app's cache (created, and deleted on stop).
    pub async fn start(
        upstream: String,
        user_agent: &str,
        dir: PathBuf,
        max_secs: f64,
        max_bytes: u64,
    ) -> io::Result<LocalHls> {
        crate::xtream::ensure_tls_provider();
        let client = reqwest::Client::builder()
            .user_agent(if user_agent.is_empty() {
                "gerdTV"
            } else {
                user_agent
            })
            .build()
            .map_err(|e| io::Error::other(e.without_url()))?;
        let token = random_token()?;
        let shared = Arc::new(Mutex::new(Shared {
            window: Window::new(dir.clone(), max_secs, max_bytes)?,
            status: Status::default(),
        }));
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}/{token}/index.m3u8", listener.local_addr()?);
        tracing::info!("local HLS on {url}");
        let serve = tokio::spawn(serve(listener, token, shared.clone()));
        let fetch = tokio::spawn(fetch(upstream, client, shared.clone()));
        Ok(LocalHls {
            url,
            shared,
            dir,
            tasks: vec![serve.abort_handle(), fetch.abort_handle()],
        })
    }

    /// The playlist URL for AVPlayer.
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn status(&self) -> Status {
        let s = self.shared.lock().unwrap();
        Status {
            window_secs: s.window.secs(),
            ..s.status.clone()
        }
    }

    /// Segments in the window (tests wait for the first few).
    pub fn segments(&self) -> usize {
        self.shared.lock().unwrap().window.len()
    }

    pub fn stop(&mut self) {
        for t in self.tasks.drain(..) {
            t.abort();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Drop for LocalHls {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 128 random bits as hex: other apps on the device can reach 127.0.0.1 but can't guess the path.
fn random_token() -> io::Result<String> {
    let mut b = [0u8; 16];
    io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut b)?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

/// Reads the provider's stream into the window until stopped, reconnecting after drops, stalls and server errors.
/// 401/403/404 stop it: those don't get better by retrying (account refused, channel gone).
async fn fetch(upstream: String, client: reqwest::Client, shared: Arc<Mutex<Shared>>) {
    let mut seg = Segmenter::new();
    let mut failures: u32 = 0;
    loop {
        let refused = read_once(&upstream, &client, &shared, &mut seg, &mut failures).await;
        {
            let mut s = shared.lock().unwrap();
            if let Some(code) = refused {
                tracing::warn!("local HLS: the provider refused the stream (HTTP {code})");
                s.status.refused = Some(code);
                s.status.reconnecting = false;
                return;
            }
            s.status.reconnecting = true;
            s.status.reconnects += 1;
        }
        seg.reset();
        let wait = (1u64 << failures.min(4)).min(MAX_BACKOFF_SECS);
        failures += 1;
        tracing::info!("local HLS: reconnecting in {wait} s");
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

/// One connection: reads until it ends, stalls or fails. Returns the status code when the provider refused it.
async fn read_once(
    upstream: &str,
    client: &reqwest::Client,
    shared: &Mutex<Shared>,
    seg: &mut Segmenter,
    failures: &mut u32,
) -> Option<u16> {
    let stall = Duration::from_secs(STALL_SECS);
    let mut resp = match tokio::time::timeout(stall, client.get(upstream).send()).await {
        Ok(Ok(r)) => r,
        _ => return None,
    };
    let code = resp.status().as_u16();
    if matches!(code, 401 | 403 | 404) {
        return Some(code);
    }
    if !resp.status().is_success() {
        return None;
    }
    while let Ok(Ok(Some(chunk))) = tokio::time::timeout(stall, resp.chunk()).await {
        let done = seg.push(&chunk);
        if done.is_empty() {
            continue;
        }
        let mut s = shared.lock().unwrap();
        for d in &done {
            if let Err(e) = s.window.add(d) {
                tracing::warn!("local HLS: can't write a segment: {e}");
            }
        }
        // Data flows again: the next drop starts the backoff from 1 s.
        s.status.reconnecting = false;
        *failures = 0;
    }
    None
}

/// Answers AVPlayer: GET /<token>/index.m3u8 and /<token>/<n>.ts, one request per connection.
async fn serve(listener: TcpListener, token: String, shared: Arc<Mutex<Shared>>) {
    while let Ok((stream, _)) = listener.accept().await {
        tokio::spawn(answer(stream, token.clone(), shared.clone()));
    }
}

async fn answer(mut stream: TcpStream, token: String, shared: Arc<Mutex<Shared>>) {
    let mut req = Vec::new();
    let mut buf = [0u8; 2048];
    while !req.windows(4).any(|w| w == b"\r\n\r\n") && req.len() < 16 * 1024 {
        match stream.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => req.extend_from_slice(&buf[..n]),
        }
    }
    let line = String::from_utf8_lossy(&req);
    let path = line
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("GET "))
        .and_then(|l| l.split(' ').next());
    let name = path.and_then(|p| {
        p.strip_prefix('/')?
            .strip_prefix(token.as_str())?
            .strip_prefix('/')
    });
    let found = name.and_then(|n| {
        let s = shared.lock().unwrap();
        if n == "index.m3u8" {
            Some((
                "application/vnd.apple.mpegurl",
                s.window.playlist().into_bytes(),
            ))
        } else {
            let seq = n.strip_suffix(".ts")?.parse().ok()?;
            Some(("video/mp2t", s.window.segment(seq)?))
        }
    });
    let reply = match found {
        Some((kind, body)) => {
            let mut r = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: {kind}\r\ncontent-length: {}\r\ncache-control: no-cache\r\n\
                 connection: close\r\n\r\n",
                body.len()
            )
            .into_bytes();
            r.extend_from_slice(&body);
            r
        }
        None => {
            b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_vec()
        }
    };
    let _ = stream.write_all(&reply).await;
}

/// This stream's segment folder under the app's cache folder (one per start; a crash leaves it for [sweep]).
pub fn stream_dir(cache_dir: &Path, n: u64) -> PathBuf {
    cache_dir.join("hls").join(n.to_string())
}

/// Deletes segment folders a crash or kill left behind (called before a new start).
pub fn sweep(cache_dir: &Path) {
    let _ = std::fs::remove_dir_all(cache_dir.join("hls"));
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::fault::LiveTs;

    /// Bytes of the endless synthetic live stream (25 fps H.264 + AAC, a keyframe every 2 s).
    fn live(secs: usize) -> Vec<u8> {
        // The clip runs at about 200 kbit/s; take enough packets for `secs` and then some.
        LiveTs::new().bytes().take(secs * 40_000).collect()
    }

    /// Keyframe cuts: every segment starts with PAT, PMT and a keyframe, lasts about SEGMENT_SECS, and the bytes
    /// arrive in odd chunk sizes (the network never hands over whole packets).
    #[test]
    fn segments_cut_at_keyframes() {
        let mut s = Segmenter::new();
        let mut segs = Vec::new();
        for chunk in live(20).chunks(1000) {
            segs.extend(s.push(chunk));
        }
        assert!(segs.len() >= 5, "{} segments", segs.len());
        for g in &segs {
            assert!((g.secs - 2.0).abs() < 0.05, "segment of {} s", g.secs);
            assert_eq!(g.data.len() % TS, 0);
            assert_eq!(packet_pid(&g.data[..TS]), 0, "PAT first");
            let mut s2 = Segmenter::new();
            // A segment on its own is a playable stream: a fresh segmenter finds its tables and a keyframe at once.
            s2.push(&g.data);
            assert!(s2.start_pts.is_some(), "no keyframe at the segment start");
            assert!(!g.discontinuity);
        }
    }

    /// After a reconnect the next segment is a discontinuity, and so is one after a timestamp jump.
    #[test]
    fn reconnects_and_jumps_mark_discontinuities() {
        let mut s = Segmenter::new();
        let bytes = live(12);
        let first: Vec<_> = s.push(&bytes);
        assert!(!first.is_empty());
        s.reset();
        // A new connection starts at an arbitrary byte, not on a packet boundary.
        let again = s.push(&bytes[1234..]);
        assert!(again[0].discontinuity);
        assert!(again[1..].iter().all(|g| !g.discontinuity));
    }

    /// The window keeps the budget's seconds (at least three segments) and counts discontinuities that leave it.
    #[test]
    fn window_trims_to_the_budget() {
        let dir = std::env::temp_dir().join(format!("gerdtv-hls-test-{}", std::process::id()));
        let mut w = Window::new(dir.clone(), 6.0, u64::MAX).unwrap();
        let seg = |d| Segment {
            data: vec![0x47; TS],
            secs: 2.0,
            discontinuity: d,
        };
        w.add(&seg(true)).unwrap();
        for _ in 0..5 {
            w.add(&seg(false)).unwrap();
        }
        let p = w.playlist();
        assert!(p.contains("#EXT-X-MEDIA-SEQUENCE:3\n"), "{p}");
        assert!(p.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1\n"), "{p}");
        assert!(p.contains("#EXT-X-TARGETDURATION:2\n"));
        assert!(!p.contains("#EXT-X-ENDLIST"));
        assert_eq!(w.len(), 3);
        assert!(w.segment(2).is_none() && w.segment(5).is_some());
        assert!(!dir.join("0.ts").exists(), "trimmed files are deleted");
        // A tiny byte budget still keeps three segments.
        let mut w = Window::new(dir.join("b"), 1e9, 1).unwrap();
        for _ in 0..5 {
            w.add(&seg(false)).unwrap();
        }
        assert_eq!(w.len(), 3);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A local HLS over the fault server's endless live TS (paced in real time: a 2 s segment every 2 s).
    async fn start(server: &gerdtv_testkit::fault::FaultServer, dir: &str) -> LocalHls {
        let dir = std::env::temp_dir().join(format!("gerdtv-hls-{dir}-{}", std::process::id()));
        LocalHls::start(server.url("/live/x.ts"), "", dir, 3600.0, u64::MAX)
            .await
            .unwrap()
    }

    async fn get(url: &str) -> (u16, String) {
        let r = reqwest::get(url).await.unwrap();
        (r.status().as_u16(), r.text().await.unwrap_or_default())
    }

    /// Waits up to `secs` for `cond` on the playlist.
    async fn wait_for(hls: &LocalHls, secs: u64, cond: impl Fn(&str) -> bool) -> String {
        for _ in 0..secs * 4 {
            let (_, p) = get(hls.url()).await;
            if cond(&p) {
                return p;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        panic!("timed out; playlist:\n{}", get(hls.url()).await.1);
    }

    /// AVPlayer's view: a live playlist whose segments it can fetch; any other path, or a wrong token, is 404; stop
    /// deletes the segments.
    #[tokio::test]
    async fn serves_playlist_and_segments() {
        let server = gerdtv_testkit::fault::FaultServer::start().await;
        let mut hls = start(&server, "serve").await;
        let p = wait_for(&hls, 15, |p| p.matches("#EXTINF").count() >= 2).await;
        let first = p.lines().find(|l| l.ends_with(".ts")).unwrap();
        let seg_url = hls.url().replace("index.m3u8", first);
        let r = reqwest::get(&seg_url).await.unwrap();
        assert_eq!(r.status(), 200);
        assert_eq!(r.bytes().await.unwrap()[0], 0x47);
        let wrong = hls.url().replace(
            &hls.url()[hls.url().len() - 43..hls.url().len() - 11],
            "0".repeat(32).as_str(),
        );
        assert_eq!(get(&wrong).await.0, 404, "a guessed token gets nothing");
        assert_eq!(get(&hls.url().replace("index.m3u8", "999.ts")).await.0, 404);
        assert_eq!(server.stats().live_ts, 1, "one provider connection");
        hls.stop();
        assert!(!hls.dir.exists());
    }

    /// A provider drop and a stall are reconnected; AVPlayer only sees discontinuities and the playlist goes on.
    #[tokio::test]
    async fn drop_and_stall_reconnect_as_discontinuities() {
        use gerdtv_testkit::fault::Fault;
        let server = gerdtv_testkit::fault::FaultServer::start().await;
        server.once(Fault::Drop {
            after_bytes: 60_000,
        });
        let hls = start(&server, "drop").await;
        wait_for(&hls, 20, |p| {
            p.split("#EXT-X-DISCONTINUITY\n")
                .nth(1)
                .is_some_and(|after| after.contains("#EXTINF"))
        })
        .await;
        assert!(hls.status().reconnects >= 1);
        // The cut drops the running connection; the reconnect then stalls, and STALL_SECS later it reconnects again.
        server.once(Fault::Stall {
            after_bytes: 60_000,
            duration: Duration::from_secs(60),
        });
        server.cut();
        wait_for(&hls, 40, |p| {
            p.matches("#EXT-X-DISCONTINUITY\n").count() >= 3 && p.ends_with(".ts\n")
        })
        .await;
        let s = hls.status();
        assert!(s.reconnects >= 3 && s.refused.is_none(), "{s:?}");
    }

    /// A refused login stops retrying and says so.
    #[tokio::test]
    async fn refused_stream_stops() {
        use gerdtv_testkit::fault::Fault;
        let server = gerdtv_testkit::fault::FaultServer::start().await;
        server.set(Fault::Status { code: 403 });
        let hls = start(&server, "refused").await;
        for _ in 0..40 {
            if hls.status().refused.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert_eq!(hls.status().refused, Some(403));
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(server.stats().faulted, 1, "no retries");
    }

    fn packet_pid(p: &[u8]) -> u16 {
        ((p[1] as u16 & 0x1f) << 8) | p[2] as u16
    }
}
