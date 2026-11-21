//! gerdtv-release: the small CLI behind the release pipeline (docs/RELEASING.md) and `just verify-release`.
//!
//! What it does, and why each part exists:
//! - `keygen`: makes the ed25519 update key pair once. The private key becomes a secret of the GitHub environment
//!   `release`; the public key is committed (keys/update-public-key.hex) and compiled into the app, which refuses any
//!   manifest that this key didn't sign.
//! - `manifest`: writes latest.json (version, notes, and per platform: asset name, size, SHA-256, minimum OS).
//! - `sign`: signs a file's exact bytes and writes `<file>.sig` (hex). The key comes from the environment variable
//!   GERDTV_UPDATE_SIGNING_KEY, so it never lands in a file on the CI runner.
//! - `verify`: checks `<file>.sig` against the public key.
//! - `check`: verifies a downloaded release folder: the manifest signature, then every asset's size and SHA-256.
//!
//! Keys and signatures are lowercase hex text (64 hex chars for keys, 128 for signatures) so they paste cleanly into
//! `gh secret set` and diff readably. Debug hints: `verify` failing right after `sign` means the public key file doesn't
//! match the secret (re-run keygen only if the old key is truly lost: the installed apps trust the old public key).

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::{env, fs, process};

const USAGE: &str = "usage:
  gerdtv-release keygen <private-key-out> <public-key-out>
  gerdtv-release manifest --version <v> --notes <file> [--asset <platform> <path> <min-os>]... > latest.json
  gerdtv-release sign <file>                      (key from env GERDTV_UPDATE_SIGNING_KEY, writes <file>.sig)
  gerdtv-release verify <public-key-file> <file>  (reads <file>.sig)
  gerdtv-release check <public-key-file> <dir>    (latest.json + .sig + every asset in <dir>)";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("keygen") if args.len() == 3 => keygen(Path::new(&args[1]), Path::new(&args[2])),
        Some("manifest") => manifest(&args[1..]).map(|m| println!("{m}")),
        Some("sign") if args.len() == 2 => sign(Path::new(&args[1])),
        Some("verify") if args.len() == 3 => verify(Path::new(&args[1]), Path::new(&args[2])),
        Some("check") if args.len() == 3 => check(Path::new(&args[1]), Path::new(&args[2])),
        _ => Err(USAGE.to_string()),
    };
    if let Err(e) = result {
        eprintln!("gerdtv-release: {e}");
        process::exit(1);
    }
}

// ---- hex (a few lines instead of another dependency) ----

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex<const N: usize>(text: &str, what: &str) -> Result<[u8; N], String> {
    let text = text.trim();
    if text.len() != N * 2 || !text.is_ascii() {
        return Err(format!(
            "{what}: expected {} hex characters, got {}",
            N * 2,
            text.len()
        ));
    }
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16)
            .map_err(|_| format!("{what}: not hex"))?;
    }
    Ok(out)
}

fn read(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn read_text(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn sig_path(file: &Path) -> PathBuf {
    let mut s = file.as_os_str().to_owned();
    s.push(".sig");
    PathBuf::from(s)
}

// ---- commands ----

fn keygen(private_out: &Path, public_out: &Path) -> Result<(), String> {
    if private_out.exists() {
        // Never overwrite: a lost update key means installed apps can't verify updates any more.
        return Err(format!(
            "{} exists; refusing to overwrite an update key",
            private_out.display()
        ));
    }
    // 32 random bytes from the OS (Linux/macOS, where this tool runs), instead of a rand dependency.
    // (read_exact, not fs::read: /dev/urandom never ends.)
    let mut seed = [0u8; 32];
    {
        use std::io::Read;
        fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut seed))
            .map_err(|e| format!("/dev/urandom: {e}"))?;
    }
    let key = SigningKey::from_bytes(&seed);
    write_private(private_out, &to_hex(&seed))?;
    fs::write(public_out, to_hex(&key.verifying_key().to_bytes()) + "\n")
        .map_err(|e| format!("{}: {e}", public_out.display()))?;
    eprintln!(
        "wrote {} (secret, mode 0600) and {}",
        private_out.display(),
        public_out.display()
    );
    Ok(())
}

/// Creates the private key file readable by the owner only.
fn write_private(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.write_all(text.as_bytes()).map_err(|e| e.to_string())
}

fn manifest(args: &[String]) -> Result<Value, String> {
    let (mut version, mut notes, mut platforms) = (None, None, serde_json::Map::new());
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--version" if i + 1 < args.len() => (version, i) = (Some(args[i + 1].clone()), i + 2),
            "--notes" if i + 1 < args.len() => {
                (notes, i) = (Some(read_text(Path::new(&args[i + 1]))?), i + 2)
            }
            "--asset" if i + 3 < args.len() => {
                let path = Path::new(&args[i + 2]);
                let bytes = read(path)?;
                let name = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .ok_or("asset path has no file name")?;
                platforms.insert(
                    args[i + 1].clone(),
                    json!({
                        "asset": name,
                        "size": bytes.len(),
                        "sha256": to_hex(&Sha256::digest(&bytes)),
                        "min_os": args[i + 3],
                    }),
                );
                i += 4;
            }
            other => return Err(format!("manifest: unexpected argument {other:?}\n{USAGE}")),
        }
    }
    let version = version.ok_or("manifest: --version is required")?;
    if platforms.is_empty() {
        return Err("manifest: at least one --asset is required".into());
    }
    Ok(json!({ "version": version, "notes": notes.unwrap_or_default(), "platforms": platforms }))
}

fn sign(file: &Path) -> Result<(), String> {
    let secret = env::var("GERDTV_UPDATE_SIGNING_KEY")
        .map_err(|_| "GERDTV_UPDATE_SIGNING_KEY is not set")?;
    sign_with(&secret, file)
}

fn sign_with(secret: &str, file: &Path) -> Result<(), String> {
    let key = SigningKey::from_bytes(&from_hex::<32>(secret, "GERDTV_UPDATE_SIGNING_KEY")?);
    let signature = key.sign(&read(file)?);
    fs::write(sig_path(file), to_hex(&signature.to_bytes()) + "\n").map_err(|e| e.to_string())?;
    // Sign-then-verify with the same key catches a truncated or mangled secret right in the release job.
    key.verifying_key()
        .verify(&read(file)?, &signature)
        .map_err(|e| e.to_string())
}

fn verify(public_key: &Path, file: &Path) -> Result<(), String> {
    let key = VerifyingKey::from_bytes(&from_hex::<32>(&read_text(public_key)?, "public key")?)
        .map_err(|e| format!("public key: {e}"))?;
    let signature =
        Signature::from_bytes(&from_hex::<64>(&read_text(&sig_path(file))?, "signature")?);
    // verify_strict rejects the malleable signature forms plain verify would accept.
    key.verify_strict(&read(file)?, &signature)
        .map_err(|_| format!("{}: signature does not match", file.display()))?;
    eprintln!("{}: signature valid", file.display());
    Ok(())
}

fn check(public_key: &Path, dir: &Path) -> Result<(), String> {
    let manifest_path = dir.join("latest.json");
    verify(public_key, &manifest_path)?;
    let manifest: Value = serde_json::from_str(&read_text(&manifest_path)?)
        .map_err(|e| format!("latest.json: {e}"))?;
    let platforms = manifest["platforms"]
        .as_object()
        .ok_or("latest.json: no platforms")?;
    for (platform, entry) in platforms {
        let name = entry["asset"]
            .as_str()
            .ok_or(format!("{platform}: no asset name"))?;
        let bytes = read(&dir.join(name))?;
        let sha = to_hex(&Sha256::digest(&bytes));
        if Some(sha.as_str()) != entry["sha256"].as_str()
            || Some(bytes.len() as u64) != entry["size"].as_u64()
        {
            return Err(format!(
                "{platform}: {name} does not match its size/SHA-256 in latest.json"
            ));
        }
        eprintln!("{platform}: {name} ok ({} bytes)", bytes.len());
    }
    println!(
        "release {} verified: {} platform assets",
        manifest["version"].as_str().unwrap_or("?"),
        platforms.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_rejects_bad_input() {
        let bytes = [0u8, 1, 0xab, 0xff];
        assert_eq!(from_hex::<4>(&to_hex(&bytes), "x").unwrap(), bytes);
        assert!(from_hex::<4>("00ff", "x").is_err(), "too short");
        assert!(from_hex::<2>("zz00", "x").is_err(), "not hex");
    }

    /// The whole release path on a temp folder: keygen → manifest → sign → check, then each tampering is caught.
    #[test]
    fn signed_release_verifies_and_tampering_fails() {
        let dir = env::temp_dir().join(format!("gerdtv-release-test-{}", process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let (private, public) = (dir.join("key"), dir.join("key.pub"));
        keygen(&private, &public).unwrap();
        assert!(keygen(&private, &public).is_err(), "never overwrites a key");

        fs::write(dir.join("gerdTV-linux-x64-1.tar.gz"), b"linux bytes").unwrap();
        fs::write(dir.join("notes.md"), "notes").unwrap();
        let args: Vec<String> = [
            "--version",
            "1",
            "--notes",
            "NOTES",
            "--asset",
            "linux",
            "ASSET",
            "-",
        ]
        .iter()
        .map(|a| match *a {
            "NOTES" => dir.join("notes.md").display().to_string(),
            "ASSET" => dir.join("gerdTV-linux-x64-1.tar.gz").display().to_string(),
            a => a.to_string(),
        })
        .collect();
        fs::write(
            dir.join("latest.json"),
            manifest(&args).unwrap().to_string(),
        )
        .unwrap();
        sign_with(&read_text(&private).unwrap(), &dir.join("latest.json")).unwrap();
        check(&public, &dir).unwrap();

        fs::write(dir.join("gerdTV-linux-x64-1.tar.gz"), b"evil bytes!").unwrap();
        assert!(
            check(&public, &dir)
                .unwrap_err()
                .contains("does not match its size/SHA-256")
        );

        fs::write(dir.join("latest.json"), "{}").unwrap();
        assert!(
            check(&public, &dir)
                .unwrap_err()
                .contains("signature does not match")
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
