//! New, because nothing owns the host's self-update: only a signed, newer, intact release is installed, the old binary
//! is kept as `.prev`, a failing `--before` command stops it, and a new version that doesn't stay up is rolled back.
//! Against the test kit's mock release server (a fixed test key, never the real update key); `restart` is faked.
use gerdtv_host::update::{self, Outcome};
use gerdtv_testkit::mock_release::{self, MockRelease, Variant};
use std::cell::Cell;
use std::os::unix::fs::PermissionsExt;

const OLD: &[u8] = b"the installed host";

#[tokio::test]
async fn the_host_installs_only_verified_releases_and_rolls_back_one_that_does_not_stay_up() {
    let key = mock_release::public_key_hex();
    let new_bytes = mock_release::asset_bytes("host");
    let new: &[u8] = &new_bytes;
    // (what the mock gets wrong, --before, whether the restarted service stays up,
    //  expected outcome, the binary afterwards, restarts)
    let cases = [
        (Variant::Valid, None, true, "updated", new, 1),
        // The new version reaches the hook (the owner's snapshot names it).
        (
            Variant::Valid,
            Some("test \"$GERDTV_UPDATE_VERSION\" = 0.261205.57"),
            true,
            "updated",
            new,
            1,
        ),
        (Variant::Valid, Some("false"), true, "error", OLD, 0),
        (Variant::Valid, None, false, "error", OLD, 2),
        (Variant::BadSignature, None, true, "error", OLD, 0),
        (Variant::BadHash, None, true, "error", OLD, 0),
        (Variant::Downgrade, None, true, "up to date", OLD, 0),
    ];
    for (i, (variant, before, stays_up, want, want_bin, want_restarts)) in
        cases.into_iter().enumerate()
    {
        let dir =
            std::env::temp_dir().join(format!("gerdtv-host-update-{}-{i}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let bin = dir.join("gerdtv-host");
        std::fs::write(&bin, OLD).unwrap();
        let mock = MockRelease::start(variant, "0.261205.57", "0.250101.1").await;
        let restarts = Cell::new(0);
        // A rollback restarts the old binary, which stays up.
        let restart = || {
            restarts.set(restarts.get() + 1);
            stays_up || restarts.get() > 1
        };
        let got = match update::run(&mock.base(), &key, "0.261122.31", &bin, before, restart).await
        {
            Ok(Outcome::Updated { to }) => {
                assert_eq!(to, "0.261205.57", "case {i}");
                "updated"
            }
            Ok(Outcome::UpToDate) => "up to date",
            Err(_) => "error",
        };
        let case = format!("case {i} ({variant:?}, before {before:?}, stays up {stays_up})");
        assert_eq!(got, want, "{case}: outcome");
        assert_eq!(std::fs::read(&bin).unwrap(), want_bin, "{case}: the binary");
        assert_eq!(restarts.get(), want_restarts, "{case}: restarts");
        if got == "updated" {
            assert_eq!(
                std::fs::read(update::prev_path(&bin)).unwrap(),
                OLD,
                "{case}: .prev keeps the old one"
            );
            let mode = std::fs::metadata(&bin).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755, "{case}: executable");
        }
        // Nothing left behind but the binary and, after an install, .prev.
        let mut left: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        let expected: &[&str] = if want_restarts > 0 {
            &["gerdtv-host", "gerdtv-host.prev"]
        } else {
            &["gerdtv-host"]
        };
        assert_eq!(left, expected, "{case}: files left");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
