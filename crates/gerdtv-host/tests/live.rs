//! Opt-in check of the host against a real Xtream Codes account (`just test-live`; ignored otherwise): it syncs, the
//! API answers without the login, and a channel's stream redirect goes to the provider's own target (one stream
//! request, no playback). Reads GERDTV_XC_SERVER, GERDTV_XC_USER, GERDTV_XC_PASS. Prints counts and yes/no only:
//! never names, URLs or credentials (the output may be pasted into a public PR).

use gerdtv_core::library::{self, Library, Profile, SourceKind};
use gerdtv_core::pairing::ProfileSecrets;
use gerdtv_host::{Config, Host, HostFile, Request, handle};
use std::collections::HashMap;

fn env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is not set (see docs/SETUP.md, live tests)"))
}

#[tokio::test]
#[ignore = "needs a real account: just test-live"]
async fn live_host_serves_without_the_login() {
    let (server, user, pass) = (
        env("GERDTV_XC_SERVER"),
        env("GERDTV_XC_USER"),
        env("GERDTV_XC_PASS"),
    );
    let dir = std::env::temp_dir().join("gerdtv-host-live");
    let _ = std::fs::remove_dir_all(&dir);
    let p = library::save_profile(
        &dir,
        Profile {
            id: String::new(),
            name: "Live".into(),
            source: SourceKind::Xtream,
            server,
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        },
    )
    .unwrap();
    let login = vec![user.clone(), pass.clone()];
    let r = Library::open(&dir, &p.id, login.clone())
        .unwrap()
        .sync()
        .await
        .unwrap();
    println!("synced: {} entries", r.stats.entries);
    let mut file = HostFile::default();
    file.secrets.profile = Some(ProfileSecrets {
        id: p.id,
        login,
        services: Default::default(),
    });
    let cfg = Config {
        dir: dir.clone(),
        front: "https://front.example.invalid".into(),
        player: "http://player.example.invalid".into(),
        listen: "127.0.0.1:0".into(),
        proxy: None,
    };
    let h = Host::new(cfg, file);
    let now = gerdtv_core::pairing::unix_now();
    let t = h.auth.lock().unwrap().new_link(now);
    let code = h.auth.lock().unwrap().open_link(&t, "live", now).unwrap();
    let sid = h.auth.lock().unwrap().take_handoff(&code, now).unwrap();
    let get = |path: &str| {
        let (path, query) = path.split_once('?').unwrap_or((path, ""));
        Request {
            method: "GET".into(),
            path: path.into(),
            query: query
                .split('&')
                .filter_map(|kv| kv.split_once('='))
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
            headers: HashMap::from([
                ("host".into(), "player.example.invalid".into()),
                ("cookie".into(), format!("gs={sid}")),
            ]),
            body: vec![],
            peer: None,
        }
    };
    let cats: serde_json::Value =
        serde_json::from_slice(&handle(&h, get("/api/categories?kind=live")).await.body).unwrap();
    let cat = cats
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["favourites"].is_null())
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let items = handle(&h, get(&format!("/api/items?kind=live&category={cat}"))).await;
    let text = String::from_utf8_lossy(&items.body).to_string();
    println!(
        "api: {} groups, login in answers: {}",
        cats.as_array().unwrap().len(),
        text.contains(&pass) || text.contains(&user)
    );
    assert!(!text.contains(&pass));
    let items: serde_json::Value = serde_json::from_slice(&items.body).unwrap();
    // The first channel the provider serves (some are dead: those answer 502, without the login); at most three tries.
    let mut last = None;
    for it in items.as_array().unwrap().iter().take(3) {
        let s = handle(&h, get(&format!("/s/{}", it["key"].as_str().unwrap()))).await;
        let refused_cleanly = s.status == 502 && !String::from_utf8_lossy(&s.body).contains(&pass);
        println!(
            "stream: {} (refused without the login: {refused_cleanly})",
            s.status
        );
        let done = s.status == 302;
        last = Some(s);
        if done {
            break;
        }
    }
    let s = last.unwrap();
    let to = s
        .headers
        .iter()
        .find(|(k, _)| k == "location")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    println!(
        "stream redirect: {}, to the provider's own target: {}, login in it: {}",
        s.status,
        !to.contains(&format!("/{user}/{pass}/")),
        to.contains(&pass)
    );
    std::fs::remove_dir_all(&dir).unwrap();
}
