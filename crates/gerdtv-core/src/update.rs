//! The in-app updater's checks (docs/RELEASING.md): read the release's signed `latest.json`, refuse anything whose
//! ed25519 signature doesn't match the compiled-in public key (`keys/update-public-key.hex`), offer only a newer
//! version that has an asset for this platform, and download that asset into a file that is kept only when its size
//! and SHA-256 match the manifest. Installing it is the platform's part (the app).
//! Debugging: every refusal says which check failed; the manifest URL is public (GitHub's latest-release download).

use ed25519_dalek::{Signature, VerifyingKey};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Where releases are published (GitHub's "latest release" download URLs; public).
pub const RELEASES: &str = "https://github.com/tzitzaki/gerdTV/releases/latest/download";

/// The newest release's page (notes and every file), for platforms without an in-app install (iOS) and for anyone
/// who wants to read more.
pub const RELEASE_PAGE: &str = "https://github.com/tzitzaki/gerdTV/releases/latest";

/// A phone's install file of release `version` itself, for a QR on a TV or computer (a phone without gerdTV gets the
/// build that pairs with the one showing it): the Android APK, or the iPhone's unsigned IPA (re-signed first,
/// docs/INSTALL.md). The names are the release job's (`.github/workflows/release.yml`, checked by a test).
pub fn phone_file(platform: &str, version: &str) -> Option<String> {
    let name = match platform {
        "android" => format!("gerdTV-android-{version}.apk"),
        "ios" => format!("gerdTV-ios-unsigned-{version}.ipa"),
        _ => return None,
    };
    Some(format!(
        "https://github.com/tzitzaki/gerdTV/releases/download/v{version}/{name}"
    ))
}

/// The update key's public half, as committed (the release job signs with the secret half).
pub const PUBLIC_KEY_HEX: &str = include_str!("../../../keys/update-public-key.hex");

#[derive(Debug, thiserror::Error)]
pub enum UpdateError {
    #[error("network error: {0}")]
    Network(String),
    #[error("the update's signature does not match (refused)")]
    Signature,
    #[error("the update's manifest is malformed: {0}")]
    Manifest(String),
    #[error("the download does not match its size or SHA-256 (deleted)")]
    Hash,
    #[error("file error: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, UpdateError>;

/// A newer release for this platform.
#[derive(Debug, Clone, PartialEq)]
pub struct Release {
    pub version: String,
    pub notes: String,
    pub asset: String,
    pub size: u64,
    pub sha256: String,
    pub min_os: String,
    pub url: String,
}

fn from_hex<const N: usize>(text: &str) -> Option<[u8; N]> {
    let t = text.trim();
    if t.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&t[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

/// "0.YYMMDD.N" as numbers, so 0.261122.9 < 0.261122.12 (a string compare would get that wrong).
fn version_key(v: &str) -> Vec<u64> {
    v.split(['.', '+', '-'])
        .take(3)
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

/// The manifest's bytes are trusted only if the signature (hex) verifies against `public_key_hex`.
pub fn verify(manifest: &[u8], signature_hex: &str, public_key_hex: &str) -> Result<()> {
    let key = from_hex::<32>(public_key_hex)
        .and_then(|k| VerifyingKey::from_bytes(&k).ok())
        .ok_or(UpdateError::Signature)?;
    let sig = from_hex::<64>(signature_hex).ok_or(UpdateError::Signature)?;
    // verify_strict: the same strictness as `gerdtv-release verify`.
    key.verify_strict(manifest, &Signature::from_bytes(&sig))
        .map_err(|_| UpdateError::Signature)
}

/// Picks this platform's newer release out of a verified manifest (None: up to date, or no build for it).
pub fn newer_release(
    manifest: &[u8],
    base: &str,
    current: &str,
    platform: &str,
) -> Result<Option<Release>> {
    let m: Value =
        serde_json::from_slice(manifest).map_err(|e| UpdateError::Manifest(e.to_string()))?;
    let version = m["version"]
        .as_str()
        .ok_or(UpdateError::Manifest("no version".into()))?;
    if version_key(version) <= version_key(current) {
        return Ok(None);
    }
    let Some(entry) = m["platforms"].get(platform) else {
        return Ok(None);
    };
    let text = |k: &str| entry[k].as_str().unwrap_or_default().to_string();
    let asset = text("asset");
    if asset.is_empty() || entry["size"].as_u64().is_none() || text("sha256").len() != 64 {
        return Err(UpdateError::Manifest(format!(
            "{platform}: incomplete entry"
        )));
    }
    Ok(Some(Release {
        version: version.to_string(),
        notes: m["notes"].as_str().unwrap_or_default().to_string(),
        url: format!("{base}/{asset}"),
        size: entry["size"].as_u64().unwrap_or(0),
        sha256: text("sha256"),
        min_os: text("min_os"),
        asset,
    }))
}

fn client() -> Result<reqwest::Client> {
    crate::xtream::ensure_tls_provider();
    reqwest::Client::builder()
        .user_agent("gerdTV")
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|e| UpdateError::Network(e.to_string()))
}

async fn get(client: &reqwest::Client, url: &str) -> Result<reqwest::Response> {
    let res = client
        .get(url)
        .send()
        .await
        .map_err(|e| UpdateError::Network(e.without_url().to_string()))?;
    if !res.status().is_success() {
        return Err(UpdateError::Network(format!(
            "HTTP {}",
            res.status().as_u16()
        )));
    }
    Ok(res)
}

/// Checks `base` (normally [RELEASES]) for a release newer than `current` with a build for `platform`.
pub async fn check(
    base: &str,
    current: &str,
    platform: &str,
    public_key_hex: &str,
) -> Result<Option<Release>> {
    let client = client()?;
    let manifest = get(&client, &format!("{base}/latest.json"))
        .await?
        .bytes()
        .await
        .map_err(|e| UpdateError::Network(e.without_url().to_string()))?;
    let sig = get(&client, &format!("{base}/latest.json.sig"))
        .await?
        .text()
        .await
        .map_err(|e| UpdateError::Network(e.without_url().to_string()))?;
    verify(&manifest, &sig, public_key_hex)?;
    newer_release(&manifest, base, current, platform)
}

/// Downloads the release's asset into `dir`; the file is kept only if its size and SHA-256 match.
pub async fn download(release: &Release, dir: &Path) -> Result<PathBuf> {
    let client = client()?;
    let mut res = get(&client, &release.url).await?;
    std::fs::create_dir_all(dir)?;
    let target = dir.join(&release.asset);
    let part = dir.join(format!("{}.part", release.asset));
    let mut hash = Sha256::new();
    let mut size = 0u64;
    {
        use std::io::Write;
        let mut f = std::io::BufWriter::new(std::fs::File::create(&part)?);
        while let Some(chunk) = res
            .chunk()
            .await
            .map_err(|e| UpdateError::Network(e.without_url().to_string()))?
        {
            hash.update(&chunk);
            size += chunk.len() as u64;
            f.write_all(&chunk)?;
        }
        f.flush()?;
    }
    let sha: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if size != release.size || sha != release.sha256 {
        let _ = std::fs::remove_file(&part);
        return Err(UpdateError::Hash);
    }
    std::fs::rename(&part, &target)?;
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_numbers() {
        let table = [
            ("0.261122.12", "0.261122.9", true),
            ("0.261123.1", "0.261122.99", true),
            ("0.261122.9", "0.261122.12", false),
            ("0.261122.12", "0.261122.12", false),
        ];
        for (a, b, newer) in table {
            assert_eq!(version_key(a) > version_key(b), newer, "{a} vs {b}");
        }
        assert_eq!(
            PUBLIC_KEY_HEX.trim().len(),
            64,
            "the committed public key is 32 bytes of hex"
        );
        assert_eq!(
            RELEASES,
            format!("{RELEASE_PAGE}/download"),
            "the release page and the files are the same release"
        );
    }

    /// The phone links name exactly the files the release job publishes, under the version's own tag.
    #[test]
    fn phone_files_are_the_release_assets() {
        let workflow = include_str!("../../../.github/workflows/release.yml");
        for (platform, asset) in [
            ("android", "gerdTV-android-$v.apk"),
            ("ios", "gerdTV-ios-unsigned-$v.ipa"),
        ] {
            assert!(workflow.contains(asset), "release.yml publishes {asset}");
            let url = phone_file(platform, "0.261127.71").unwrap();
            assert!(url.ends_with(&asset.replace("$v", "0.261127.71")), "{url}");
            assert!(url.contains("/releases/download/v0.261127.71/"), "{url}");
        }
        assert_eq!(phone_file("linux", "0.1.1"), None);
    }
}
