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
