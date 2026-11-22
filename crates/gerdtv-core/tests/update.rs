//! New, because nothing owned the updater's refusals: against the test kit's mock release server, one row per thing
//! a release can get wrong. The mock signs with a fixed test key, never the real update key.
use gerdtv_core::update::{self, UpdateError};
use gerdtv_testkit::mock_release::{self, MockRelease, Variant};

#[tokio::test]
async fn the_updater_offers_only_signed_newer_releases_and_verified_files() {
    let key = mock_release::public_key_hex();
    let dir = std::env::temp_dir().join(format!("gerdtv-update-{}", std::process::id()));
    // (what the mock gets wrong, expected check result, expected download result)
    let cases = [
        (Variant::Valid, "offer", "ok"),
        (Variant::BadSignature, "signature", "-"),
        (Variant::BadHash, "offer", "hash"),
        (Variant::Downgrade, "none", "-"),
        (Variant::MissingPlatform, "none", "-"),
        (Variant::NetworkError, "network", "-"),
    ];
    for (variant, want_check, want_download) in cases {
        let mock = MockRelease::start(variant, "0.261205.57", "0.250101.1").await;
        let checked = update::check(&mock.base(), "0.261122.31", "linux", &key).await;
        let got = match &checked {
            Ok(Some(_)) => "offer",
            Ok(None) => "none",
            Err(UpdateError::Signature) => "signature",
            Err(UpdateError::Network(_)) => "network",
            Err(e) => panic!("{variant:?}: unexpected {e}"),
        };
        assert_eq!(got, want_check, "{variant:?}: check");
        if let Ok(Some(release)) = checked {
            assert_eq!(release.version, "0.261205.57");
            let downloaded = update::download(&release, &dir).await;
            let got = match &downloaded {
                Ok(path) => {
                    assert_eq!(std::fs::metadata(path).unwrap().len(), release.size);
                    "ok"
                }
                Err(UpdateError::Hash) => {
                    assert!(
                        !dir.join(&release.asset).exists(),
                        "a mismatching file is not kept"
                    );
                    "hash"
                }
                Err(e) => panic!("{variant:?}: unexpected {e}"),
            };
            assert_eq!(got, want_download, "{variant:?}: download");
            let _ = std::fs::remove_file(dir.join(&release.asset));
        }
    }
    // The real key is not the test key: a mock release must never pass with it.
    let mock = MockRelease::start(Variant::Valid, "0.261205.57", "0.250101.1").await;
    assert!(matches!(
        update::check(&mock.base(), "0.261122.31", "linux", update::PUBLIC_KEY_HEX).await,
        Err(UpdateError::Signature)
    ));
    let _ = std::fs::remove_dir_all(&dir);
}
