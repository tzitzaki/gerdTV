//! Recording a live channel (owner decision: direct stream capture in the core): the provider's MPEG-TS as it comes,
//! written to a file, until a stop time or [Recording::stop]. Its own short read loop rather than hls.rs's, which cuts
//! segments for AVPlayer: a recording needs the bytes unchanged.
//!
//! Drops, stalls and server errors reconnect with backoff (1, 2, 4, 8, 10, 10 … s); a gap in the file is the price,
//! mpv plays across it. 401/403/404 end it as refused (the account or channel won't get better by retrying). A write
//! that fails (disk full, the folder gone) ends it as failed with the reason, keeping what was written.
//! One recording takes one provider connection, which the app counts against the account's limit (scheduler).
//! Debug hints: the upstream URL carries the login and is never logged; `status()` says why a recording ended.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// No bytes for this long: the connection is dead, reconnect.
const STALL_SECS: u64 = 10;
const MAX_BACKOFF_SECS: u64 = 10;

#[derive(Debug, Clone, PartialEq, Default)]
pub enum Ended {
    #[default]
    Running,
    /// The stop time came, or the user stopped it.
    Done,
    /// 401/403/404 from the provider.
    Refused(u16),
    /// A write failed: the reason (e.g. no space left).
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Status {
    pub bytes: u64,
    pub reconnects: u32,
    pub ended: Ended,
}

/// A running recording; stops when dropped.
pub struct Recording {
    status: Arc<Mutex<Status>>,
    task: tokio::task::JoinHandle<()>,
    stop: Arc<tokio::sync::Notify>,
}

impl Recording {
    /// Starts writing `upstream` into `file` (created by the caller: a path on desktop, a file descriptor from the
    /// system's folder picker on Android) until `until` (UTC seconds).
    pub fn start(
        upstream: String,
        user_agent: &str,
        file: std::fs::File,
        until: i64,
    ) -> std::io::Result<Recording> {
        crate::xtream::ensure_tls_provider();
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(STALL_SECS))
            .user_agent(if user_agent.is_empty() {
                "gerdTV"
            } else {
                user_agent
            })
            .build()
            .map_err(|e| std::io::Error::other(e.without_url()))?;
        let status = Arc::new(Mutex::new(Status::default()));
        let stop = Arc::new(tokio::sync::Notify::new());
        let task = tokio::spawn(run(
            upstream,
            client,
            file,
            until,
            status.clone(),
            stop.clone(),
        ));
        Ok(Recording { status, task, stop })
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    /// Ends it now (the file keeps what was written). Returns once the file is closed.
    pub async fn stop(self) -> Status {
        self.stop.notify_one();
        let _ = (&mut { self.task }).await;
        self.status.lock().unwrap().clone()
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

async fn run(
    upstream: String,
    client: reqwest::Client,
    mut file: std::fs::File,
    until: i64,
    status: Arc<Mutex<Status>>,
    stop: Arc<tokio::sync::Notify>,
) {
    let end = |s: &Mutex<Status>, e: Ended| s.lock().unwrap().ended = e;
    let mut failures: u32 = 0;
    loop {
        let left = until - now();
        if left <= 0 {
            break end(&status, Ended::Done);
        }
        let read = read_once(&upstream, &client, &mut file, &status, &mut failures);
        let outcome = tokio::select! {
            o = read => o,
            _ = stop.notified() => break end(&status, Ended::Done),
            _ = tokio::time::sleep(Duration::from_secs(left as u64)) => break end(&status, Ended::Done),
        };
        match outcome {
            Outcome::Refused(code) => break end(&status, Ended::Refused(code)),
            Outcome::Failed(why) => break end(&status, Ended::Failed(why)),
            Outcome::Retry => {}
        }
        status.lock().unwrap().reconnects += 1;
        let wait = (1u64 << failures.min(4)).min(MAX_BACKOFF_SECS);
        failures += 1;
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
            _ = stop.notified() => break end(&status, Ended::Done),
        }
    }
    let _ = file.flush();
}

enum Outcome {
    Retry,
    Refused(u16),
    Failed(String),
}

/// One connection: appends its bytes until it ends, stalls or fails.
async fn read_once(
    upstream: &str,
    client: &reqwest::Client,
    file: &mut std::fs::File,
    status: &Mutex<Status>,
    failures: &mut u32,
) -> Outcome {
    let stall = Duration::from_secs(STALL_SECS);
    let mut resp = match tokio::time::timeout(stall, client.get(upstream).send()).await {
        Ok(Ok(r)) => r,
        _ => return Outcome::Retry,
    };
    let code = resp.status().as_u16();
    if matches!(code, 401 | 403 | 404) {
        return Outcome::Refused(code);
    }
    if !resp.status().is_success() {
        return Outcome::Retry;
    }
    while let Ok(Ok(Some(chunk))) = tokio::time::timeout(stall, resp.chunk()).await {
        if let Err(e) = file.write_all(&chunk) {
            return Outcome::Failed(e.to_string());
        }
        status.lock().unwrap().bytes += chunk.len() as u64;
        *failures = 0; // data flows again: the next drop starts the backoff from 1 s
    }
    Outcome::Retry
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::fault::{Fault, FaultServer};

    fn file(name: &str) -> (std::path::PathBuf, std::fs::File) {
        let p = std::env::temp_dir().join(format!("gerdtv-rec-{name}-{}.ts", std::process::id()));
        (p.clone(), std::fs::File::create(&p).unwrap())
    }

    /// New, because nothing owns recording: it writes until its stop time across a drop, and the file is MPEG-TS.
    #[tokio::test]
    async fn records_until_the_stop_time_across_a_drop() {
        let server = FaultServer::start().await;
        server.once(Fault::Drop {
            after_bytes: 40_000,
        });
        let (path, f) = file("drop");
        let r = Recording::start(server.url("/live/x.ts"), "", f, now() + 3).unwrap();
        tokio::time::sleep(Duration::from_secs(4)).await;
        let s = r.status();
        assert_eq!(s.ended, Ended::Done, "{s:?}");
        assert!(s.reconnects >= 1 && s.bytes > 40_000, "{s:?}");
        let data = std::fs::read(&path).unwrap();
        assert_eq!(
            (data.len() as u64, data[0]),
            (s.bytes, 0x47),
            "TS sync byte first"
        );
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn a_refused_stream_ends_at_once_and_stop_ends_it_early() {
        let server = FaultServer::start().await;
        server.set(Fault::Status { code: 403 });
        let (path, f) = file("refused");
        let r = Recording::start(server.url("/live/x.ts"), "", f, now() + 60).unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert_eq!(r.status().ended, Ended::Refused(403));
        assert_eq!(server.stats().faulted, 1, "no retries");
        std::fs::remove_file(path).unwrap();

        server.set(Fault::None);
        let (path, f) = file("stop");
        let r = Recording::start(server.url("/live/x.ts"), "", f, now() + 60).unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
        let s = r.stop().await;
        assert!(s.ended == Ended::Done && s.bytes > 0, "{s:?}");
        std::fs::remove_file(path).unwrap();
    }
}
