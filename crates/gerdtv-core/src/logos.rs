//! Logo disk cache: channel logos and posters are downloaded once into the app's cache folder and read from disk
//! after that (Flutter's image cache is memory-only, so every start would fetch thousands of logos again).
//! Files are named by a stable hash of the URL (FNV-1a, 64 bit); the OS may clear the cache folder at any time.
//! At most [PARALLEL] downloads run at once, a logo larger than [MAX_BYTES] is refused, and a URL that failed is not
//! tried again until the app restarts (dead logo links are common in provider lists).
//! Debugging: a missing logo is a failed URL (wrong status, timeout, too large); the URL itself is never logged.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::Semaphore;

/// Concurrent downloads: a list shows ~20 logos at once; more would only queue at the provider.
pub const PARALLEL: usize = 6;
/// Logos are small (typically 5–50 kB); anything bigger is a wrong link or a full-size poster we don't need.
pub const MAX_BYTES: usize = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(15);

pub struct LogoCache {
    dir: PathBuf,
    client: reqwest::Client,
    permits: Semaphore,
    failed: Mutex<HashSet<String>>,
}

/// FNV-1a over the URL bytes: stable across Rust versions (std's hasher is not), so files survive app updates.
fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

impl LogoCache {
    pub fn new(dir: PathBuf) -> LogoCache {
        crate::xtream::ensure_tls_provider();
        LogoCache {
            dir,
            client: reqwest::Client::builder()
                .user_agent("gerdTV")
                .timeout(TIMEOUT)
                .build()
                .expect("a client without custom TLS settings always builds"),
            permits: Semaphore::new(PARALLEL),
            failed: Mutex::new(HashSet::new()),
        }
    }

    pub fn path_for(&self, url: &str) -> PathBuf {
        self.dir.join(format!("{:016x}", fnv1a(url)))
    }

    /// The logo's file, downloading it first if needed; None when the URL fails (remembered until restart).
    pub async fn get(&self, url: &str) -> Option<PathBuf> {
        let path = self.path_for(url);
        if path.is_file() {
            return Some(path);
        }
        if !url.starts_with("http") || self.failed.lock().unwrap().contains(url) {
            return None;
        }
        let _permit = self.permits.acquire().await.ok()?;
        // Another call may have fetched it while this one waited for a permit.
        if path.is_file() {
            return Some(path);
        }
        match self.fetch(url, &path).await {
            Some(()) => Some(path),
            None => {
                self.failed.lock().unwrap().insert(url.to_string());
                None
            }
        }
    }

    async fn fetch(&self, url: &str, path: &PathBuf) -> Option<()> {
        let mut res = self.client.get(url).send().await.ok()?;
        if !res.status().is_success() {
            return None;
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = res.chunk().await.ok()? {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > MAX_BYTES {
                return None;
            }
        }
        if bytes.is_empty() {
            return None;
        }
        // Written beside the target and renamed, so a half-written file is never shown.
        std::fs::create_dir_all(&self.dir).ok()?;
        let tmp = path.with_extension("part");
        std::fs::write(&tmp, &bytes).ok()?;
        std::fs::rename(&tmp, path).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A tiny HTTP server: /ok.png answers a few bytes, /big.png more than MAX_BYTES, anything else 404.
    async fn server(hits: Arc<AtomicUsize>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let (mut s, _) = listener.accept().await.unwrap();
                hits.fetch_add(1, Ordering::SeqCst);
                let mut buf = [0u8; 1024];
                let n = s.read(&mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let body: Vec<u8> = if req.starts_with("GET /ok.png") {
                    b"\x89PNG fake".to_vec()
                } else if req.starts_with("GET /big.png") {
                    vec![0u8; MAX_BYTES + 1]
                } else {
                    let _ = s
                        .write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")
                        .await;
                    continue;
                };
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: {}\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes()).await;
                let _ = s.write_all(&body).await;
            }
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn logos_are_fetched_once_and_failures_not_retried() {
        let hits = Arc::new(AtomicUsize::new(0));
        let base = server(hits.clone()).await;
        let dir = std::env::temp_dir().join(format!("gerdtv-logos-{}", std::process::id()));
        let cache = LogoCache::new(dir.clone());
        // (path, should be cached, server hits after this and a second call)
        let table = [
            ("/ok.png", true, 1),
            ("/missing.png", false, 2),
            ("/big.png", false, 3),
        ];
        for (path, ok, want_hits) in table {
            let url = format!("{base}{path}");
            for _ in 0..2 {
                assert_eq!(cache.get(&url).await.is_some(), ok, "{path}");
            }
            assert_eq!(
                hits.load(Ordering::SeqCst),
                want_hits,
                "{path}: one request, never two"
            );
        }
        assert_eq!(
            std::fs::read(cache.path_for(&format!("{base}/ok.png"))).unwrap(),
            b"\x89PNG fake"
        );
        // A fresh cache (an app restart) still reads the file from disk.
        let again = LogoCache::new(dir.clone());
        assert!(again.get(&format!("{base}/ok.png")).await.is_some());
        assert_eq!(hits.load(Ordering::SeqCst), 3);
        assert!(cache.get("not a url").await.is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
