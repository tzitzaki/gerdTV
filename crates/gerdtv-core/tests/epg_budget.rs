//! The guide import budget at full scale (docs/SPEC.md budgets): 2,000 channels × 7 days ≈ 300 MB of XMLTV imported
//! in under 60 s. Ignored by default (it writes ~300 MB through SQLite); `just test-epg-budget` and the nightly run it.
use gerdtv_core::{db, epg};
use std::path::Path;
use std::time::{Duration, Instant};

#[test]
#[ignore = "slow: just test-epg-budget"]
fn import_2000_channels_7_days_under_60s() {
    let now = 1_763_683_200 + 86_400;
    let mut xml = Vec::new();
    gerdtv_testkit::generate::write_xmltv(&mut xml, 2000, 7, now - 86_400, 1).unwrap();
    let dir = std::env::temp_dir().join(format!("gerdtv-epg-budget-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut conn = db::open(&dir.join("p.db")).unwrap();
    let t = Instant::now();
    let stats = epg::import(&mut conn, 1, xml.as_slice(), now, 2, 7, 0).unwrap();
    let took = t.elapsed();
    println!(
        "epg import: {} MB, {} programmes in {:.1} s",
        xml.len() / 1_000_000,
        stats.programmes,
        took.as_secs_f64()
    );
    drop(conn);
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(took < Duration::from_secs(60), "{took:?}");
}
