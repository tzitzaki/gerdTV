//! Shared by the host's tests: a host serving the testkit's mock panel, with one paired app ("phone").

use gerdtv_core::library::{self, Library, Profile, SourceKind};
use gerdtv_core::pairing::{self, Device, Peer, ProfileSecrets};
use gerdtv_host::{Config, Host, HostFile};
use gerdtv_testkit::mock_xc::{MockXc, PASS, USER};
use std::sync::Arc;

/// A host with the mock panel's profile, synced, and one paired app ("phone", `key`).
pub async fn host(mock: &MockXc, key: &str, front: &str, player: &str, listen: &str) -> Arc<Host> {
    let dir = std::env::temp_dir().join(format!("gerdtv-host-{}", pairing::new_device_id()));
    let p = library::save_profile(
        &dir,
        Profile {
            id: String::new(),
            name: "Mock".into(),
            source: SourceKind::Xtream,
            server: mock.base(),
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        },
    )
    .unwrap();
    let login = vec![USER.to_string(), PASS.to_string()];
    Library::open(&dir, &p.id, login.clone())
        .unwrap()
        .sync()
        .await
        .unwrap();
    let mut file = HostFile::default();
    file.secrets.profile = Some(ProfileSecrets {
        id: p.id,
        login,
        services: Default::default(),
    });
    file.peers.push(Peer {
        device: Device {
            id: "phone".into(),
            name: "Phone".into(),
            platform: "android".into(),
        },
        key: key.into(),
        addr: String::new(),
        web: String::new(),
    });
    let cfg = Config {
        dir,
        front: front.into(),
        player: player.into(),
        listen: listen.into(),
        proxy: None,
    };
    Host::new(cfg, file)
}
