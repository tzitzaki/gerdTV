//! New, because nothing owns the web player in a browser: the real server (socket layer included) and the page in
//! headless Chrome (tests/web_smoke.mjs over Chrome's DevTools protocol): login link → hand-over → groups → channels
//! → search → player → movies' tiles → +3 h → no cookie: "Session ended". Needs Chrome and Node, so it is ignored by
//! default: `just test-web`. Screenshots go to ~/gerdTV-screens/<branch>/web-*.png.

mod common;

use common::host;
use gerdtv_core::pairing::{self, AppRequest, Peer};
use gerdtv_testkit::mock_xc::MockXc;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs Chrome and Node: just test-web"]
async fn the_page_logs_in_browses_and_plays_in_chrome() {
    let mock = MockXc::start(300, 3).await;
    let key = pairing::hex(&pairing::random::<32>());
    // Two names for the same server, so the front door and the player differ by host as in production.
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let front = format!("http://127.0.0.1:{port}");
    let player = format!("http://localhost:{port}");
    let h = host(&mock, &key, &front, &player, &format!("127.0.0.1:{port}")).await;
    tokio::spawn(gerdtv_host::serve(h.clone()));
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    // The link, asked for the way the app asks (sealed, over HTTP).
    let peer = Peer {
        device: pairing::Device {
            id: "host".into(),
            name: String::new(),
            platform: String::new(),
        },
        key,
        addr: String::new(),
        web: front.clone(),
    };
    let req = AppRequest {
        ts: pairing::unix_now(),
        op: "link".into(),
        id: String::new(),
    };
    let answer = pairing::app_request(&front, "phone", &peer, &req)
        .await
        .unwrap();
    let link = answer["url"].as_str().unwrap().to_string();
    let branch = std::process::Command::new("git")
        .args(["branch", "--show-current"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let shots = format!("{}/gerdTV-screens/{branch}", std::env::var("HOME").unwrap());
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/web_smoke.mjs");
    // std's process in a blocking task: the server keeps running on the runtime meanwhile.
    let out = tokio::task::spawn_blocking(move || {
        std::process::Command::new("node")
            .args([script, &link, &shots])
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.status.success(), "{text}");
}
