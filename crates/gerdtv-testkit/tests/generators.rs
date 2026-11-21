//! Owns: the synthetic fixtures are big enough to measure the performance budgets against.
use gerdtv_testkit::generate::{Counter, write_m3u, write_xmltv};

#[test]
fn m3u_fixture_has_150k_entries() {
    let mut out = Counter::default();
    assert_eq!(write_m3u(&mut out, 150_000, 1).unwrap(), 150_000);
    // Real 150k playlists are 40–60 MB; ours must be in that range to be a fair parse benchmark.
    assert!(
        (30_000_000..70_000_000).contains(&out.0),
        "M3U size {} bytes",
        out.0
    );
}

#[test]
fn xmltv_fixture_is_2000_channels_by_7_days() {
    let mut out = Counter::default();
    let programmes = write_xmltv(&mut out, 2000, 7, 1_763_683_200, 1).unwrap();
    // ≈ 2,000 × 7 × 19 programmes a day; ≈ 300 MB uncompressed, the import budget's size.
    assert!(
        (200_000..320_000).contains(&programmes),
        "{programmes} programmes"
    );
    assert!(
        (250_000_000..350_000_000).contains(&out.0),
        "XMLTV size {} bytes",
        out.0
    );
}
