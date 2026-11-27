//! A mock of the GitHub release download URLs the in-app updater reads:
//!   /latest.json, /latest.json.sig, /<asset>
//! in the format `gerdtv-release manifest` writes (docs/RELEASING.md), signed with a fixed test key (never the real
//! update key). Each `Variant` breaks one thing the updater must refuse or survive.

use crate::http::{self, Handler, Server};
use ed25519_dalek::{Signer, SigningKey};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

/// The test key's seed: fixed so tests can compile in the matching public key.
const TEST_SEED: [u8; 32] = [7; 32];
const PLATFORMS: [&str; 5] = ["macos", "ios", "android", "linux", "host"];

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Variant {
    /// Correct manifest, signature and assets.
    Valid,
    /// The signature doesn't match the manifest.
    BadSignature,
    /// An asset's bytes don't match its SHA-256 in the manifest.
    BadHash,
    /// Signed correctly, but the version is older than `current`.
    Downgrade,
    /// The manifest has no entry for "linux" or "host".
    MissingPlatform,
    /// Every request fails with HTTP 500.
    NetworkError,
}

pub struct MockRelease {
    server: Server,
    variant: Arc<Mutex<Variant>>,
}

/// The test key's public half, hex (what a test build of the updater trusts).
pub fn public_key_hex() -> String {
    SigningKey::from_bytes(&TEST_SEED)
        .verifying_key()
        .to_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn asset_name(platform: &str, version: &str) -> String {
    match platform {
        "macos" => format!("gerdTV-macos-{version}.zip"),
        "ios" => format!("gerdTV-ios-unsigned-{version}.ipa"),
        "android" => format!("gerdTV-android-{version}.apk"),
        "host" => format!("gerdTV-host-linux-x64-{version}"),
        _ => format!("gerdTV-linux-x64-{version}.tar.gz"),
    }
}

/// A platform's synthetic build (what a verified download must contain).
pub fn asset_bytes(platform: &str) -> Vec<u8> {
    format!("synthetic {platform} build").into_bytes()
}

impl MockRelease {
    /// `newer` is the version the mock offers (e.g. "0.261205.57"); `older` the one a downgrade offers.
    pub async fn start(variant: Variant, newer: &str, older: &str) -> MockRelease {
        let variant = Arc::new(Mutex::new(variant));
        let v = variant.clone();
        let (newer, older) = (newer.to_string(), older.to_string());
        let handler: Handler = Arc::new(move |req, stream| {
            let variant = *v.lock().unwrap();
            let version = if variant == Variant::Downgrade {
                older.clone()
            } else {
                newer.clone()
            };
            Box::pin(async move {
                if variant == Variant::NetworkError {
                    return http::respond(stream, 500, "text/plain", b"").await;
                }
                let manifest = manifest(variant, &version);
                let path = req.path.trim_start_matches('/');
                match path {
                    "latest.json" => {
                        http::respond(stream, 200, "application/json", manifest.as_bytes()).await
                    }
                    "latest.json.sig" => {
                        let key = SigningKey::from_bytes(&TEST_SEED);
                        let signed = if variant == Variant::BadSignature {
                            b"something else".to_vec()
                        } else {
                            manifest.into_bytes()
                        };
                        let sig: String = key
                            .sign(&signed)
                            .to_bytes()
                            .iter()
                            .map(|b| format!("{b:02x}"))
                            .collect();
                        http::respond(stream, 200, "text/plain", format!("{sig}\n").as_bytes())
                            .await
                    }
                    name => match PLATFORMS.iter().find(|p| asset_name(p, &version) == name) {
                        Some(p) => {
                            let mut bytes = asset_bytes(p);
                            if variant == Variant::BadHash {
                                bytes.push(b'!');
                            }
                            http::respond(stream, 200, "application/octet-stream", &bytes).await
                        }
                        None => http::respond(stream, 404, "text/plain", b"").await,
                    },
                }
            })
        });
        MockRelease {
            server: Server::start(handler).await,
            variant,
        }
    }

    /// The base URL standing in for https://github.com/<owner>/<repo>/releases/latest/download.
    pub fn base(&self) -> String {
        self.server.url("")
    }

    pub fn set_variant(&self, v: Variant) {
        *self.variant.lock().unwrap() = v;
    }
}

fn manifest(variant: Variant, version: &str) -> String {
    let mut platforms = serde_json::Map::new();
    for p in PLATFORMS {
        if variant == Variant::MissingPlatform && (p == "linux" || p == "host") {
            continue;
        }
        let bytes = asset_bytes(p);
        let sha: String = Sha256::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        platforms.insert(
            p.to_string(),
            json!({ "asset": asset_name(p, version), "size": bytes.len(), "sha256": sha, "min_os": "-" }),
        );
    }
    json!({ "version": version, "notes": "## Changes\n- Synthetic release.", "platforms": platforms }).to_string()
}
