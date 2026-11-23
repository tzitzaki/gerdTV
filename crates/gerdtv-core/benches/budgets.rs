//! The core's performance budgets (docs/SPEC.md, "Performance budgets"), measured on the synthetic fixtures.
//! `just bench` runs this and fails on a regression of more than 20 % against the saved baseline.
use criterion::{Criterion, criterion_group, criterion_main};
use gerdtv_core::db;
use gerdtv_testkit::generate::write_m3u;
use std::path::Path;
use std::time::Duration;

fn playlist(n: usize) -> Vec<u8> {
    let mut v = Vec::new();
    write_m3u(&mut v, n, 1).unwrap();
    v
}

fn budgets(c: &mut Criterion) {
    let pl = playlist(150_000);
    let mut g = c.benchmark_group("budgets");
    g.sample_size(10).measurement_time(Duration::from_secs(20));
    // Budget: ≥ 100k entries/s parse; 150k parse + import < 5 s.
    g.bench_function("m3u_parse_150k", |b| {
        b.iter(|| gerdtv_core::m3u::parse(pl.as_slice(), drop).unwrap())
    });
    g.bench_function("m3u_import_150k", |b| {
        b.iter(|| {
            let mut conn = db::open(Path::new(":memory:")).unwrap();
            db::import_m3u(&mut conn, pl.as_slice(), &["testuser", "testpass"]).unwrap()
        })
    });
    g.finish();

    // Budget: search < 50 ms p95 on the full catalogue (EPG and TMDB rows join in Phase 4).
    let mut conn = db::open(Path::new(":memory:")).unwrap();
    db::import_m3u(&mut conn, pl.as_slice(), &["testuser", "testpass"]).unwrap();
    let mut g = c.benchmark_group("search");
    // "port": mid-word (trigram) hits; "spotr", "munchne": typo lookups in the vocabulary.
    for q in [
        "s",
        "sport",
        "sport mu",
        "munchen kino",
        "de | reise",
        "12",
        "port",
        "spotr",
        "munchne",
    ] {
        g.bench_function(format!("search_{q}"), |b| {
            b.iter(|| db::search(&conn, q, &[], None, 50, 0).unwrap())
        });
    }
    g.bench_function("counts_sport", |b| {
        b.iter(|| db::search_counts(&conn, "sport").unwrap())
    });
    g.bench_function("groups_sport", |b| {
        b.iter(|| db::search_groups(&conn, "sport", &[db::Kind::Live], 5).unwrap())
    });
    g.finish();
}

/// The guide: import of 200 channels × 7 days (the full 2,000-channel budget is a timed test, `epg_budget.rs`),
/// the grid's window query (50 channels × 3 h; budget < 20 ms) and now/next for 100 channels (budget < 5 ms).
fn guide(c: &mut Criterion) {
    use gerdtv_core::epg;
    let now = 1_763_683_200 + 86_400; // inside the generated guide's first days
    let mut xml = Vec::new();
    gerdtv_testkit::generate::write_xmltv(&mut xml, 200, 7, now - 86_400, 1).unwrap();
    let mut pl = Vec::new();
    write_m3u(&mut pl, 2000, 1).unwrap(); // 600 live channels, epg ids ch0, ch10 … match the guide's channels
    let mut g = c.benchmark_group("guide");
    g.sample_size(10);
    g.bench_function("import_200ch_7d", |b| {
        b.iter(|| {
            let mut conn = db::open(Path::new(":memory:")).unwrap();
            epg::import(&mut conn, 1, xml.as_slice(), now, 2, 7, 0).unwrap()
        })
    });
    let mut conn = db::open(Path::new(":memory:")).unwrap();
    db::import_m3u(&mut conn, pl.as_slice(), &[]).unwrap();
    epg::import(&mut conn, 1, xml.as_slice(), now, 2, 7, 0).unwrap();
    epg::rebuild_matches(&mut conn).unwrap();
    let keys: Vec<String> = {
        let mut st = conn
            .prepare("SELECT item_key FROM item_epg LIMIT 100")
            .unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };
    g.bench_function("now_next_100", |b| {
        b.iter(|| epg::now_next(&conn, &keys, now).unwrap())
    });
    g.bench_function("window_50ch_3h", |b| {
        b.iter(|| epg::window(&conn, &keys[..50], now, now + 3 * 3600).unwrap())
    });
    g.finish();
}

criterion_group!(benches, budgets, guide);
criterion_main!(benches);
