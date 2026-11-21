//! Owns: every fault type of the fault server is injectable and behaves as documented (src/fault.rs).
use gerdtv_testkit::fault::{Fault, FaultServer};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// Reads a response: (status, body bytes read until close or `limit`, whether the server closed the stream).
async fn get(url: &str, limit: usize, timeout: Duration) -> (u16, usize, bool) {
    let rest = url.strip_prefix("http://").unwrap();
    let (host, path) = rest.split_at(rest.find('/').unwrap());
    let mut s = TcpStream::connect(host).await.unwrap();
    s.write_all(format!("GET {path} HTTP/1.1\r\nHost: {host}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut buf = vec![0u8; 64 * 1024];
    let mut all = Vec::new();
    let deadline = Instant::now() + timeout;
    let mut closed = false;
    while all.len() < limit + 1024 {
        let left = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(left, s.read(&mut buf)).await {
            Ok(Ok(0)) | Ok(Err(_)) => {
                closed = true;
                break;
            }
            Ok(Ok(n)) => all.extend_from_slice(&buf[..n]),
            Err(_) => break,
        }
    }
    let head_end = all
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap_or(all.len());
    let status = String::from_utf8_lossy(&all[..head_end])
        .split(' ')
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    (status, all.len() - head_end, closed)
}

#[tokio::test]
async fn faults_are_injectable() {
    let srv = FaultServer::start().await;
    let live = srv.url("/live/ch1.ts");

    // Healthy live TS: keeps streaming (not closed) and starts with TS packets.
    let (status, n, closed) = get(&live, 100_000, Duration::from_secs(2)).await;
    assert_eq!((status, closed), (200, false));
    assert!(n >= 33_000, "about a second's burst at once, got {n}");

    // Drop: the connection is cut after the given bytes.
    srv.once(Fault::Drop {
        after_bytes: 20_000,
    });
    let (_, n, closed) = get(&live, 1_000_000, Duration::from_secs(3)).await;
    assert!(
        closed && n < 30_000,
        "dropped after ~20 kB, got {n} closed={closed}"
    );

    // Stall: bytes stop arriving but the connection stays open.
    srv.once(Fault::Stall {
        after_bytes: 10_000,
        duration: Duration::from_secs(5),
    });
    let (_, n, closed) = get(&live, 1_000_000, Duration::from_secs(1)).await;
    assert!(!closed && n < 20_000, "stalled after ~10 kB, got {n}");

    // Throttle: far below the clip's ~33 kB/s.
    srv.once(Fault::Throttle {
        bytes_per_sec: 5_000,
    });
    let (_, n, _) = get(&live, 1_000_000, Duration::from_secs(2)).await;
    assert!(n < 25_000, "throttled, got {n}");

    // Status: 5xx and 403 without a body.
    for code in [503, 403] {
        srv.once(Fault::Status { code });
        assert_eq!(get(&live, 0, Duration::from_secs(1)).await.0, code);
    }

    // Live EOF: a clean end of the "endless" stream.
    srv.once(Fault::LiveEof {
        after_bytes: 15_000,
    });
    let (status, n, closed) = get(&live, 1_000_000, Duration::from_secs(3)).await;
    assert!(status == 200 && closed && n < 25_000);

    // Standing faults stay until healed; `once` faults don't.
    srv.set(Fault::Status { code: 500 });
    assert_eq!(get(&live, 0, Duration::from_secs(1)).await.0, 500);
    assert_eq!(get(&live, 0, Duration::from_secs(1)).await.0, 500);
    srv.set(Fault::None);
    assert_eq!(get(&live, 0, Duration::from_millis(300)).await.0, 200);

    // HLS: playlist and its segments (also with rotating URLs), and VOD with a full body.
    let (status, _, _) = get(
        &srv.url("/live/ch1.m3u8?rotate=1"),
        10_000,
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(status, 200);
    let (status, n, closed) = get(
        &srv.url("/hls/ch1/7-123.ts"),
        1_000_000,
        Duration::from_secs(2),
    )
    .await;
    assert!(status == 200 && closed && n > 50_000);
    let (status, n, _) = get(&srv.url("/vod/movie.ts"), 1_000_000, Duration::from_secs(2)).await;
    assert!(status == 200 && n > 300_000);

    // Over HTTP (for the Flutter integration tests): a one-shot 502, then healthy again.
    assert_eq!(
        get(
            &srv.url("/_fault/once?kind=status&n=502"),
            100,
            Duration::from_secs(1)
        )
        .await
        .0,
        200
    );
    assert_eq!(get(&live, 0, Duration::from_secs(1)).await.0, 502);
    assert_eq!(
        get(
            &srv.url("/_fault/once?kind=bogus"),
            100,
            Duration::from_secs(1)
        )
        .await
        .0,
        400
    );

    let stats = srv.stats();
    assert!(
        stats.live_ts >= 10
            && stats.live_hls_playlists == 1
            && stats.hls_segments == 1
            && stats.vod == 1
    );
    assert!(stats.faulted >= 8);
}
