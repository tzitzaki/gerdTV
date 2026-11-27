//! New, because nothing owns the web player's server: login links work once and for 10 minutes, sessions last 3 h
//! and extend by 3 h while valid, the API needs a session, nothing it sends carries the provider login, the stream
//! redirect hands over the provider's own target, and only paired apps' fresh requests are answered. Against the
//! testkit's mock panel; requests go straight to `handle` (the socket layer is the Playwright smoke's, `just test-web`).

mod common;

use common::host;
use gerdtv_core::pairing::{self, AppRequest};
use gerdtv_host::{Auth, Host, LINK_TTL, Request, SESSION_TTL, handle};
use gerdtv_testkit::mock_xc::{MockXc, PASS};
use std::collections::HashMap;

const FRONT: &str = "https://front.example.invalid";
const PLAYER: &str = "http://player.example.invalid";

fn req(method: &str, host: &str, path: &str, cookie: Option<&str>, body: &[u8]) -> Request {
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    let mut headers = HashMap::from([("host".to_string(), host.to_string())]);
    if let Some(c) = cookie {
        headers.insert("cookie".into(), format!("gs={c}"));
    }
    Request {
        method: method.into(),
        path: path.into(),
        query: query
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        headers,
        body: body.to_vec(),
        peer: Some("127.0.0.1".parse().unwrap()),
    }
}

/// The app's sealed request through the front door; the opened answer.
async fn app(h: &Host, key: &str, op: &str, ts: i64) -> (u16, serde_json::Value) {
    let r = AppRequest {
        ts,
        op: op.into(),
        id: String::new(),
    };
    let (env, nonce) = pairing::seal_app_request("phone", key, &r).unwrap();
    let res = handle(
        h,
        req(
            "POST",
            "front.example.invalid",
            "/app",
            None,
            &serde_json::to_vec(&env).unwrap(),
        ),
    )
    .await;
    if res.status != 200 {
        return (res.status, serde_json::Value::Null);
    }
    let body: serde_json::Value = serde_json::from_slice(&res.body).unwrap();
    // Opened the way the app does (pairing.rs app_request).
    let answer = pairing::open_app_answer(key, &nonce, body["sealed"].as_str().unwrap()).unwrap();
    (200, answer)
}

fn location(r: &gerdtv_host::Response) -> String {
    r.headers
        .iter()
        .find(|(k, _)| k == "location")
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

#[tokio::test]
async fn a_link_logs_in_once_and_the_session_serves_the_catalogue_without_the_login() {
    let mock = MockXc::start(300, 3).await;
    let key = pairing::hex(&pairing::random::<32>());
    let h = host(&mock, &key, FRONT, PLAYER, "127.0.0.1:0").await;
    let now = pairing::unix_now();

    // The paired app gets a link; the front door turns it into a hand-over to the player.
    let (status, link) = app(&h, &key, "link", now).await;
    assert_eq!(status, 200);
    let url = link["url"].as_str().unwrap();
    assert!(url.starts_with(&format!("{FRONT}/l/")));
    let path = &url[FRONT.len()..];
    let opened = handle(&h, req("GET", "front.example.invalid", path, None, b"")).await;
    assert_eq!(opened.status, 302);
    let to = location(&opened);
    assert!(to.starts_with(&format!("{PLAYER}/h/")), "{to}");
    // Once only.
    assert_eq!(
        handle(&h, req("GET", "front.example.invalid", path, None, b""))
            .await
            .status,
        410
    );

    // Without the hand-over's cookie the API refuses; with it, it answers.
    assert_eq!(
        handle(
            &h,
            req("GET", "player.example.invalid", "/api/session", None, b"")
        )
        .await
        .status,
        401
    );
    let set = handle(
        &h,
        req(
            "GET",
            "player.example.invalid",
            &to[PLAYER.len()..],
            None,
            b"",
        ),
    )
    .await;
    let cookie = set
        .headers
        .iter()
        .find(|(k, _)| k == "set-cookie")
        .unwrap()
        .1
        .clone();
    assert!(cookie.contains("HttpOnly") && cookie.contains("SameSite=Lax"));
    let sid = cookie
        .trim_start_matches("gs=")
        .split(';')
        .next()
        .unwrap()
        .to_string();
    let get = |path: &str| req("GET", "player.example.invalid", path, Some(&sid), b"");
    let mut seen = String::new();
    for path in [
        "/api/session",
        "/api/categories?kind=live",
        "/api/categories?kind=movie",
        "/api/search?kind=live&q=a",
        "/api/favkeys",
    ] {
        let r = handle(&h, get(path)).await;
        assert_eq!(
            r.status,
            200,
            "{path}: {}",
            String::from_utf8_lossy(&r.body)
        );
        seen.push_str(&String::from_utf8_lossy(&r.body));
    }
    let cats: serde_json::Value =
        serde_json::from_slice(&handle(&h, get("/api/categories?kind=live")).await.body).unwrap();
    let cat = cats[0]["id"].as_str().unwrap();
    let items = handle(&h, get(&format!("/api/items?kind=live&category={cat}"))).await;
    seen.push_str(&String::from_utf8_lossy(&items.body));
    let items: serde_json::Value = serde_json::from_slice(&items.body).unwrap();
    assert!(
        !seen.contains(PASS),
        "no response carries the provider's password"
    );

    // The stream redirect hands over the panel's own target (its streaming node), not the login.
    let key0 = items[0]["key"].as_str().unwrap();
    let s = handle(&h, get(&format!("/s/{key0}"))).await;
    assert_eq!(s.status, 302);
    assert!(!location(&s).contains(PASS), "{}", location(&s));
    assert!(
        location(&s).starts_with("http://127.0.0.1"),
        "the mock's streaming node: {}",
        location(&s)
    );

    // Favourites and positions write into the host's profile.
    let fav = req(
        "POST",
        "player.example.invalid",
        "/api/favourite",
        Some(&sid),
        format!(r#"{{"key":"{key0}","on":true}}"#).as_bytes(),
    );
    assert_eq!(handle(&h, fav).await.status, 200);
    assert!(String::from_utf8_lossy(&handle(&h, get("/api/favkeys")).await.body).contains(key0));

    // The app lists the session and ends it; the API refuses it then.
    let (_, list) = app(&h, &key, "sessions", now).await;
    assert_eq!(list["sessions"].as_array().unwrap().len(), 1);
    let r = AppRequest {
        ts: now,
        op: "end".into(),
        id: sid.clone(),
    };
    let (env, _) = pairing::seal_app_request("phone", &key, &r).unwrap();
    handle(
        &h,
        req(
            "POST",
            "front.example.invalid",
            "/app",
            None,
            &serde_json::to_vec(&env).unwrap(),
        ),
    )
    .await;
    assert_eq!(handle(&h, get("/api/session")).await.status, 401);

    // Another host name is nobody's.
    assert_eq!(
        handle(&h, req("GET", "other.example.invalid", "/", None, b""))
            .await
            .status,
        404
    );
}

#[tokio::test]
async fn only_fresh_requests_from_paired_apps_are_answered() {
    let mock = MockXc::start(10, 1).await;
    let key = pairing::hex(&pairing::random::<32>());
    let h = host(&mock, &key, FRONT, PLAYER, "127.0.0.1:0").await;
    let now = pairing::unix_now();
    // A stranger's key, a stale request, garbage: refused.
    assert_eq!(
        app(&h, &pairing::hex(&pairing::random::<32>()), "link", now)
            .await
            .0,
        400
    );
    assert_eq!(app(&h, &key, "link", now - 3600).await.0, 400);
    assert_eq!(
        handle(
            &h,
            req("POST", "front.example.invalid", "/app", None, b"{}")
        )
        .await
        .status,
        400
    );
    // The same sealed request twice: only once.
    let r = AppRequest {
        ts: now,
        op: "link".into(),
        id: String::new(),
    };
    let (env, _) = pairing::seal_app_request("phone", &key, &r).unwrap();
    let body = serde_json::to_vec(&env).unwrap();
    assert_eq!(
        handle(
            &h,
            req("POST", "front.example.invalid", "/app", None, &body)
        )
        .await
        .status,
        200
    );
    assert_eq!(
        handle(
            &h,
            req("POST", "front.example.invalid", "/app", None, &body)
        )
        .await
        .status,
        400
    );
    // After ten failures the address waits.
    for _ in 0..10 {
        handle(
            &h,
            req("GET", "front.example.invalid", "/l/nothing", None, b""),
        )
        .await;
    }
    assert_eq!(app(&h, &key, "link", now).await.0, 429);
}

#[test]
fn links_run_out_after_10_minutes_and_sessions_after_3_hours_unless_extended() {
    let mut a = Auth::default();
    let t = a.new_link(1000);
    assert!(
        a.open_link(&t, "ua", 1000 + LINK_TTL + 1).is_none(),
        "too old"
    );
    let t = a.new_link(1000);
    let code = a.open_link(&t, "ua", 1000).unwrap();
    let sid = a.take_handoff(&code, 1001).unwrap();
    assert!(
        a.take_handoff(&code, 1001).is_none(),
        "the hand-over works once"
    );
    assert!(a.session(&sid, 1000 + SESSION_TTL - 1).is_some());
    // Extended while valid: 3 h from then.
    assert_eq!(
        a.extend(&sid, 1000 + SESSION_TTL - 1),
        Some(1000 + 2 * SESSION_TTL - 1)
    );
    assert!(a.session(&sid, 1000 + 2 * SESSION_TTL - 2).is_some());
    assert!(a.session(&sid, 1000 + 2 * SESSION_TTL).is_none());
    // Over: no extension.
    assert_eq!(a.extend(&sid, 1000 + 2 * SESSION_TTL), None);
}
