//! Opt-in checks against a real Xtream Codes account (`just test-live`; ignored otherwise). Reads GERDTV_XC_SERVER,
//! GERDTV_XC_USER, GERDTV_XC_PASS. Prints counts and timings only: never names, URLs or credentials (the output
//! may be pasted into a public PR).
use gerdtv_core::db::{self, Hit, Kind, Sort};
use gerdtv_core::xtream::{self, Xtream};
use std::time::Instant;

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is not set (see docs/SETUP.md, live tests)"))
}

#[tokio::test]
#[ignore = "needs a real account: just test-live"]
async fn live_xtream_sync() {
    let (server, user, pass) = (
        env("GERDTV_XC_SERVER"),
        env("GERDTV_XC_USER"),
        env("GERDTV_XC_PASS"),
    );
    let xc = Xtream::new(&server, &user, &pass, None);

    let t = Instant::now();
    let account = xc.account().await.expect("account");
    println!(
        "account: max_connections={} active={} ({} ms)",
        account.max_connections,
        account.active_connections,
        t.elapsed().as_millis()
    );

    let t = Instant::now();
    let cats = xc.categories().await.expect("categories");
    println!(
        "categories: {} in {} ms",
        cats.len(),
        t.elapsed().as_millis()
    );
    for kind in [Kind::Live, Kind::Movie, Kind::Series] {
        let t = Instant::now();
        let n = xc.streams(kind).await.expect("streams").len();
        println!(
            "{kind:?}: {n} streams, full list in {} ms",
            t.elapsed().as_millis()
        );
    }

    let dir = std::env::temp_dir().join(format!("gerdtv-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut conn = db::open(&dir.join("live.db")).unwrap();
    let t = Instant::now();
    let (_, stats) = xtream::sync(&mut conn, &xc).await.expect("sync");
    println!(
        "sync: {} entries, {} categories in {} ms",
        stats.entries,
        stats.categories,
        t.elapsed().as_millis()
    );
    let t = Instant::now();
    let again = xtream::sync(&mut conn, &xc).await.expect("re-sync").1;
    println!(
        "re-sync: {} entries, {} removed in {} ms",
        again.entries,
        again.removed,
        t.elapsed().as_millis()
    );
    for q in ["s", "sport", "news hd", "1"] {
        let t = Instant::now();
        let hits = db::search(&conn, q, &[], None, 50, 0).unwrap().len();
        println!(
            "search {q:?}: {hits} hits (first page) in {} µs",
            t.elapsed().as_micros()
        );
    }
    drop(conn);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The library path the app uses, on the real account: sync, a series' episodes, play URLs with the right
/// container extension, and one 15 s playback probe with the mpv CLI (if installed). Prints no names or URLs.
#[tokio::test]
#[ignore = "needs a real account: just test-live"]
async fn live_library_and_one_playback_probe() {
    use gerdtv_core::library::{self, Library, Profile, SourceKind};
    let dir = std::env::temp_dir().join(format!("gerdtv-live-lib-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let p = library::save_profile(
        &dir,
        Profile {
            id: String::new(),
            name: "live".into(),
            source: SourceKind::Xtream,
            server: env("GERDTV_XC_SERVER"),
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        },
    )
    .unwrap();
    let lib = Library::open(
        &dir,
        &p.id,
        vec![env("GERDTV_XC_USER"), env("GERDTV_XC_PASS")],
    )
    .unwrap();
    let r = lib.sync().await.expect("sync");
    println!("library sync: {} entries", r.stats.entries);
    let series_cat = &lib.categories(Kind::Series, Sort::Provider).unwrap()[0];
    let series = &lib
        .items(Kind::Series, &series_cat.id, Sort::Provider, 1, 0)
        .unwrap()[0];
    let eps = lib.episodes(&series.key).await.expect("episodes");
    println!("first series: {} episodes", eps.len());
    let movie = &lib
        .items(
            Kind::Movie,
            &lib.categories(Kind::Movie, Sort::Provider).unwrap()[0].id,
            Sort::Provider,
            1,
            0,
        )
        .unwrap()[0];
    let movie_url = lib.stream_url(&movie.key, "ts").unwrap();
    println!(
        "movie container: .{}",
        movie_url.rsplit('.').next().unwrap_or("?")
    );
    if let Some(e) = eps.first() {
        let u = lib.stream_url(&e.key, "ts").unwrap();
        println!(
            "episode container: .{}",
            u.rsplit('.').next().unwrap_or("?")
        );
    }
    // The guide: the panel's xmltv.php imported; how many live channels show a programme now.
    let t = std::time::Instant::now();
    let sources = lib.refresh_guide(7).await.expect("guide");
    println!(
        "guide: {} channels, {} programmes in {:.1} s, status {:?}",
        sources[0].channels,
        sources[0].programmes,
        t.elapsed().as_secs_f64(),
        if sources[0].status.is_empty() {
            "ok"
        } else {
            "error"
        }
    );
    let mut live_keys = vec![];
    for cat in lib.categories(Kind::Live, Sort::Provider).unwrap() {
        live_keys.extend(
            lib.items(Kind::Live, &cat.id, Sort::Provider, 10_000, 0)
                .unwrap()
                .into_iter()
                .map(|h| h.key),
        );
    }
    let unmatched = lib.unmatched_channels(100_000, 0, "").unwrap().len();
    let on_now = lib
        .now_next(&live_keys)
        .unwrap()
        .iter()
        .filter(|(n, _)| n.is_some())
        .count();
    println!(
        "guide match: {} of {} live channels matched ({} %), {} show a programme right now",
        live_keys.len() - unmatched,
        live_keys.len(),
        100 * (live_keys.len() - unmatched) / live_keys.len().max(1),
        on_now
    );

    // Catch-up: which URL form this panel answers, for a slot two hours back on up to three archive channels. One
    // request at a time, at most 20 s each; prints status codes and whether TS bytes came back, nothing else.
    let archive: Vec<Hit> = lib
        .categories(Kind::Live, Sort::Provider)
        .unwrap()
        .iter()
        .flat_map(|c| {
            lib.items(Kind::Live, &c.id, Sort::Provider, 10_000, 0)
                .unwrap()
        })
        .filter(|h| h.archive_days > 0)
        .collect();
    println!("catch-up: {} live channels have an archive", archive.len());
    let start = (now_secs() - 7200) / 1800 * 1800;
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap();
    'catchup: for ch in archive.iter().skip(5).take(3) {
        let Some(a) = lib.catchup_url(&ch.key, start, start + 1800).unwrap() else {
            continue;
        };
        // The other common form, built from the same parts: /streaming/timeshift.php?…
        let (base, rest) = a.split_once("/timeshift/").unwrap();
        let p: Vec<&str> = rest.split('/').collect();
        let b = format!(
            "{base}/streaming/timeshift.php?username={}&password={}&stream={}&start={}&duration={}",
            p[0],
            p[1],
            p[4].trim_end_matches(".ts"),
            p[3],
            p[2]
        );
        for (form, url) in [("timeshift path", a), ("timeshift.php", b)] {
            let mut kind = String::new();
            let (status, ts) = match http.get(&url).send().await {
                Ok(mut res) => {
                    let status = res.status().as_u16();
                    let ctype = res
                        .headers()
                        .get("content-type")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("-")
                        .to_string();
                    let mut bytes = Vec::new();
                    while bytes.len() < 188 * 4 {
                        match res.chunk().await {
                            Ok(Some(c)) => bytes.extend_from_slice(&c),
                            _ => break,
                        }
                    }
                    // What came back, without content: type, size, and a playlist or the first two bytes.
                    let head = if bytes.starts_with(b"#EXTM3U") {
                        "HLS playlist".to_string()
                    } else {
                        bytes.iter().take(2).map(|b| format!("{b:02x}")).collect()
                    };
                    kind = format!(", {ctype}, {} bytes, starts {head}", bytes.len());
                    // MPEG-TS packets are 188 bytes, each starting with 0x47; an archive may start mid-packet, so look
                    // for that rhythm at any offset within the first packet.
                    let ts =
                        (0..188).any(|k| (0..3).all(|i| bytes.get(k + i * 188) == Some(&0x47)));
                    (status, ts)
                }
                Err(e) => (if e.is_timeout() { 0 } else { 1 }, false),
            };
            println!(
                "catch-up probe ({form}): status {status}, TS {}{kind}",
                if ts { "yes" } else { "no" }
            );
            if ts {
                break 'catchup;
            }
        }
    }

    // One probe at a time, each at most 20 s (the provider allows few connections). The first channels of a list
    // are often separators or offline placeholders, so try a channel from each of the first groups, TS then HLS.
    let groups = lib.categories(Kind::Live, Sort::Provider).unwrap();
    'probe: for (g, cat) in groups.iter().enumerate().skip(1).take(3) {
        let ch = &lib
            .items(Kind::Live, &cat.id, Sort::Provider, 1, 0)
            .unwrap()[0];
        for hls in [false, true] {
            let url = lib
                .stream_url(&ch.key, if hls { "m3u8" } else { "ts" })
                .unwrap();
            let status = std::process::Command::new("timeout")
                .args([
                    "20",
                    "mpv",
                    "--vo=null",
                    "--ao=null",
                    "--ytdl=no",
                    "--really-quiet",
                    "--frames=250",
                    "--network-timeout=10",
                ])
                .arg(&url)
                .status();
            match status {
                Ok(s) => {
                    println!(
                        "live probe: group {g}, {}: {s}",
                        if hls { "m3u8" } else { "ts" }
                    );
                    if s.success() {
                        break 'probe;
                    }
                }
                Err(_) => {
                    println!("live probe skipped: no mpv on PATH");
                    break 'probe;
                }
            }
        }
    }
    drop(lib);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// How many live channels show a guide: the provider's alone, then with a community country file added (the
/// presets in Settings → Guide). Prints counts only, no names or URLs of the provider; no stream is opened.
#[tokio::test]
#[ignore = "needs a real account: just test-live"]
async fn live_guide_gaps() {
    use gerdtv_core::library::{self, Library, Profile, SourceKind};
    let dir = std::env::temp_dir().join(format!("gerdtv-live-gaps-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let p = library::save_profile(
        &dir,
        Profile {
            id: String::new(),
            name: "live".into(),
            source: SourceKind::Xtream,
            server: env("GERDTV_XC_SERVER"),
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        },
    )
    .unwrap();
    let lib = Library::open(
        &dir,
        &p.id,
        vec![env("GERDTV_XC_USER"), env("GERDTV_XC_PASS")],
    )
    .unwrap();
    lib.sync().await.expect("sync");
    let mut live_keys = vec![];
    for cat in lib.categories(Kind::Live, Sort::Provider).unwrap() {
        live_keys.extend(
            lib.items(Kind::Live, &cat.id, Sort::Provider, 10_000, 0)
                .unwrap()
                .into_iter()
                .map(|h| h.key),
        );
    }
    let report = |label: &str| {
        let unmatched = lib.unmatched_channels(100_000, 0, "").unwrap().len();
        let on_now = lib
            .now_next(&live_keys)
            .unwrap()
            .iter()
            .filter(|(n, _)| n.is_some())
            .count();
        println!(
            "{label}: {} of {} live channels matched, {} show a programme now",
            live_keys.len() - unmatched,
            live_keys.len(),
            on_now
        );
    };
    lib.refresh_guide(3).await.expect("guide");
    report("provider guide");
    lib.add_guide_url("https://epgshare01.online/epgshare01/epg_ripper_DE1.xml.gz")
        .unwrap();
    let t = std::time::Instant::now();
    let sources = lib.refresh_guide(3).await.expect("guide");
    println!(
        "community DE file: {} channels, {} programmes, refresh {:.1} s, status {}",
        sources[1].channels,
        sources[1].programmes,
        t.elapsed().as_secs_f64(),
        if sources[1].status.is_empty() {
            "ok"
        } else {
            "error"
        }
    );
    report("provider + community DE");
    std::fs::remove_dir_all(&dir).unwrap();
}
