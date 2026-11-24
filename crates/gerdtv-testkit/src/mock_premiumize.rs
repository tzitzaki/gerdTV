//! A mock of Premiumize's API (https://www.premiumize.me/api), enough for the cloud browser and the device login:
//!   GET  /api/account/info   /api/folder/list[?id=]   /api/transfer/list      (Authorization: Bearer <KEY>)
//!   POST /token   response_type=device_code | grant_type=device_code&code=…   (client_id = CLIENT_ID)
//! Like the real service, a wrong key is HTTP 200 with `{"status":"error","message":…}`, and the device poll answers
//! HTTP 400 `authorization_pending` until `confirm()`. The cloud is a fixed, synthetic tree; links point at
//! `example.invalid`.

use crate::http::{self, Handler, Request, Server};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

pub const KEY: &str = "pmtestkey";
pub const CLIENT_ID: &str = "pmtestclient";
const DEVICE_CODE: &str = "devcode123";

pub struct MockPremiumize {
    server: Server,
    confirmed: Arc<AtomicBool>,
}

impl MockPremiumize {
    pub async fn start() -> MockPremiumize {
        let confirmed = Arc::new(AtomicBool::new(false));
        let c = confirmed.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let (status, body) = answer(&req, c.load(Ordering::SeqCst));
            Box::pin(async move {
                http::respond(
                    stream,
                    status,
                    "application/json",
                    body.to_string().as_bytes(),
                )
                .await;
            })
        });
        MockPremiumize {
            server: Server::start(handler).await,
            confirmed,
        }
    }

    /// The base URL (in place of https://www.premiumize.me).
    pub fn base(&self) -> String {
        self.server.url("")
    }

    /// The user typed the code on premiumize.me/device: the next poll gets the token.
    pub fn confirm(&self) {
        self.confirmed.store(true, Ordering::SeqCst);
    }
}

fn file(id: &str, name: &str, mime: &str) -> Value {
    json!({ "id": id, "name": name, "type": "file", "size": 1_000_000, "created_at": 1_700_000_000,
            "mime_type": mime, "link": format!("https://dl.example.invalid/{id}/{name}") })
}

fn answer(req: &Request, confirmed: bool) -> (u16, Value) {
    if req.path == "/token" {
        if req.param("client_id") != Some(CLIENT_ID) {
            return (400, json!({ "error": "invalid_client" }));
        }
        if req.param("response_type") == Some("device_code") {
            return (
                200,
                json!({ "device_code": DEVICE_CODE, "user_code": "ABCD-1234",
                                 "verification_uri": "https://www.premiumize.me/device",
                                 "expires_in": 600, "interval": 5 }),
            );
        }
        return match (req.param("code"), confirmed) {
            (Some(DEVICE_CODE), true) => (
                200,
                json!({ "access_token": KEY, "token_type": "Bearer",
                                                       "expires_in": 3600, "scope": "full" }),
            ),
            (Some(DEVICE_CODE), false) => (400, json!({ "error": "authorization_pending" })),
            _ => (400, json!({ "error": "invalid_grant" })),
        };
    }
    if req.header("authorization") != Some(&format!("Bearer {KEY}")) {
        return (
            200,
            json!({ "status": "error", "message": "authentication_failed" }),
        );
    }
    let body = match (req.path.as_str(), req.param("id")) {
        ("/api/account/info", _) => {
            json!({ "status": "success", "customer_id": 1, "premium_until": 1_900_000_000 })
        }
        ("/api/folder/list", None) => json!({ "status": "success", "name": "root", "content": [
            file("f2", "Notes.txt", "text/plain"),
            { "id": "d1", "name": "Films", "type": "folder", "created_at": 1_700_000_000 },
            file("f1", "Show.S01E01.mkv", "video/x-matroska"),
        ]}),
        ("/api/folder/list", Some("d1")) => {
            json!({ "status": "success", "name": "Films", "content": [
                file("f3", "A Film (2019).mp4", "video/mp4"),
            ]})
        }
        ("/api/folder/list", Some(_)) => json!({ "status": "error", "message": "not_found" }),
        ("/api/transfer/list", _) => json!({ "status": "success", "transfers": [
            { "id": "t1", "name": "Another Film", "status": "running", "progress": 0.42, "message": "",
              "folder_id": null, "file_id": null },
            { "id": "t2", "name": "Films", "status": "finished", "progress": 1, "message": "",
              "folder_id": "d1", "file_id": null },
        ]}),
        _ => return (404, json!({})),
    };
    (200, body)
}
