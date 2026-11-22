//! Opt-in checks against a real Xtream Codes account (`just test-live`; ignored otherwise). Reads GERDTV_XC_SERVER,
//! GERDTV_XC_USER, GERDTV_XC_PASS. Prints counts and timings only: never names, URLs or credentials (the output
//! may be pasted into a public PR).
use gerdtv_core::db::{self, Kind};
use gerdtv_core::xtream::{self, Xtream};
use std::time::Instant;

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
        let hits = db::search(&conn, q, None, 50, 0).unwrap().len();
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
            epg_urls: vec![],
            user_agent: String::new(),
            epg_offset_hours: 0,
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
    let series_cat = &lib.categories(Kind::Series).unwrap()[0];
    let series = &lib.items(Kind::Series, &series_cat.id, 1, 0).unwrap()[0];
    let eps = lib.episodes(&series.key).await.expect("episodes");
    println!("first series: {} episodes", eps.len());
    let movie = &lib
        .items(
            Kind::Movie,
            &lib.categories(Kind::Movie).unwrap()[0].id,
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
    // One probe at a time, each at most 20 s (the provider allows few connections). The first channels of a list
    // are often separators or offline placeholders, so try a channel from each of the first groups, TS then HLS.
    let groups = lib.categories(Kind::Live).unwrap();
    'probe: for (g, cat) in groups.iter().enumerate().skip(1).take(3) {
        let ch = &lib.items(Kind::Live, &cat.id, 1, 0).unwrap()[0];
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
