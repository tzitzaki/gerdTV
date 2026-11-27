//! `gerdtv-host update`: the host updates itself from the newest release, with the same checks as the in-app updater
//! (gerdtv-core `update`: latest.json signed with the update key, the binary's size and SHA-256 from it), then:
//!   1. the optional `--before` command runs (the owner's VM snapshot); failing it stops the update,
//!   2. the running binary is kept as `<bin>.prev` and the new one renamed over `<bin>` (same folder, so atomic;
//!      the running process keeps its old file),
//!   3. the service is restarted; if it doesn't stay up, `<bin>.prev` goes back and the service is restarted again.
//!
//! Run as root by a timer (docs/INSTALL.md), because the service's own user can't write the binary's folder.
//! Debugging: every failure is one line on stderr and exit code 1 (the timer's unit then shows as failed);
//! `gerdtv-host --version` says which binary is installed, the service's start log which one runs.

use gerdtv_core::update;
use std::path::{Path, PathBuf};
use std::process::Command;

/// `latest.json`'s key for the host binary (release.yml `--asset host`).
pub const PLATFORM: &str = "host";

#[derive(Debug, PartialEq)]
pub enum Outcome {
    UpToDate,
    Updated { to: String },
}

/// `<bin>.prev`: the version before the last update (the rollback, by hand too).
pub fn prev_path(bin: &Path) -> PathBuf {
    PathBuf::from(format!("{}.prev", bin.display()))
}

/// Updates `bin` (the installed binary, version `current`) from the release at `base`.
/// `restart` restarts the service and answers whether it stayed up; it is called again after a rollback.
pub async fn run(
    base: &str,
    public_key_hex: &str,
    current: &str,
    bin: &Path,
    before: Option<&str>,
    restart: impl Fn() -> bool,
) -> Result<Outcome, String> {
    let Some(release) = update::check(base, current, PLATFORM, public_key_hex)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(Outcome::UpToDate);
    };
    let dir = bin.parent().ok_or("the binary has no folder")?;
    // Downloaded next to the binary, so the swap below is a rename on the same file system.
    let new = update::download(&release, dir)
        .await
        .map_err(|e| e.to_string())?;
    let v = &release.version;
    if let Err(e) = prepare(&new, before, v) {
        let _ = std::fs::remove_file(&new);
        return Err(e);
    }
    let prev = prev_path(bin);
    std::fs::copy(bin, &prev).map_err(|e| format!("can't keep {}: {e}", prev.display()))?;
    std::fs::rename(&new, bin).map_err(|e| format!("can't install {v}: {e}"))?;
    eprintln!("update: installed {v} (was {current}), restarting");
    if restart() {
        return Ok(Outcome::Updated { to: v.clone() });
    }
    // Back via a copy and a rename: writing straight into the binary would fail while it runs (text file busy).
    let back = PathBuf::from(format!("{}.rollback", bin.display()));
    std::fs::copy(&prev, &back)
        .and_then(|_| std::fs::rename(&back, bin))
        .map_err(|e| format!("{v} did not stay up, and going back failed: {e}"))?;
    let up = restart();
    Err(format!(
        "{v} did not stay up; went back to {current}{}",
        if up {
            ""
        } else {
            ", which does not stay up either"
        }
    ))
}

/// Makes the download executable, then runs the `--before` command (with the new version in GERDTV_UPDATE_VERSION).
fn prepare(new: &Path, before: Option<&str>, version: &str) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(new, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| e.to_string())?;
    if let Some(cmd) = before {
        let ok = Command::new("sh")
            .args(["-c", cmd])
            .env("GERDTV_UPDATE_VERSION", version)
            .status()
            .is_ok_and(|s| s.success());
        if !ok {
            return Err(format!(
                "the --before command failed; {version} not installed"
            ));
        }
    }
    Ok(())
}
