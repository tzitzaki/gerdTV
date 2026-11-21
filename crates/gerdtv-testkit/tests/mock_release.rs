//! Owns: the mock release server offers every case the updater must handle, signed like a real release.
use ed25519_dalek::{Signature, VerifyingKey};
use gerdtv_testkit::http::get;
use gerdtv_testkit::mock_release::{MockRelease, Variant, public_key_hex};
use serde_json::Value;
use sha2::{Digest, Sha256};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.trim().len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s.trim()[i..i + 2], 16).unwrap())
        .collect()
}

/// (signature valid, manifest version, linux asset hash matches)
async fn inspect(r: &MockRelease) -> (bool, String, Option<bool>) {
    let (_, _, manifest) = get(&format!("{}/latest.json", r.base())).await;
    let (_, _, sig) = get(&format!("{}/latest.json.sig", r.base())).await;
    let key = VerifyingKey::from_bytes(&unhex(&public_key_hex()).try_into().unwrap()).unwrap();
    let sig = Signature::from_bytes(&unhex(&String::from_utf8(sig).unwrap()).try_into().unwrap());
    let valid = key.verify_strict(&manifest, &sig).is_ok();
    let m: Value = serde_json::from_slice(&manifest).unwrap();
    let linux = match m["platforms"].get("linux") {
        None => None,
        Some(p) => {
            let (_, _, bytes) =
                get(&format!("{}/{}", r.base(), p["asset"].as_str().unwrap())).await;
            let sha: String = Sha256::digest(&bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            Some(Some(sha.as_str()) == p["sha256"].as_str())
        }
    };
    (valid, m["version"].as_str().unwrap().to_string(), linux)
}

#[tokio::test]
async fn release_variants() {
    let r = MockRelease::start(Variant::Valid, "0.261205.57", "0.250101.1").await;
    let cases = [
        (Variant::Valid, (true, "0.261205.57", Some(true))),
        (Variant::BadSignature, (false, "0.261205.57", Some(true))),
        (Variant::BadHash, (true, "0.261205.57", Some(false))),
        (Variant::Downgrade, (true, "0.250101.1", Some(true))),
        (Variant::MissingPlatform, (true, "0.261205.57", None)),
    ];
    for (variant, (valid, version, linux)) in cases {
        r.set_variant(variant);
        assert_eq!(
            inspect(&r).await,
            (valid, version.to_string(), linux),
            "{variant:?}"
        );
    }
    r.set_variant(Variant::NetworkError);
    assert_eq!(get(&format!("{}/latest.json", r.base())).await.0, 500);
}
