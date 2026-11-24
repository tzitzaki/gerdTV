//! gerdTV test kit. Grows in Phase 0 step 7: synthetic playlists and EPG, mock Xtream Codes and TMDB servers, the
//! fault-injection stream server, a fake Cast receiver and a mock release server. Everything it generates is
//! synthetic (`example.invalid` URLs); real provider output never goes into the repo (CLAUDE.md, "Public repo hygiene").
//!
//! `tests/repo_rules.rs` holds the checks on the repository itself (workflows, docs, HANDOVER limits, ARB files).

pub mod fault;
pub mod generate;
pub mod http;
pub mod mock_premiumize;
pub mod mock_release;
pub mod mock_tmdb;
pub mod mock_tracking;
pub mod mock_xc;

use std::path::PathBuf;

/// The repository root, found from this crate's manifest dir (crates/gerdtv-testkit → ../..).
pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root exists")
}
