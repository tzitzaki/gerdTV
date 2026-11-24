//! A mock of the Trakt and Simkl endpoints gerdTV uses, on one server (their paths don't overlap):
//!   Trakt: POST /oauth/device/code, /oauth/device/token (400 while pending), /oauth/token (refresh)
//!   Simkl: POST /oauth2/device, /oauth2/token (device_code or refresh_token grant; error names while pending)
//!   both:  POST /scrobble/start|pause|stop with `Authorization: Bearer <token>`, recorded for the test
//! The code is confirmed by `confirm()`; `reset()` starts the next service's link from scratch.

use crate::http::{self, Handler, Request, Server};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

pub const CLIENT_ID: &str = "trackclient";
pub const SECRET: &str = "tracksecret";

#[derive(Default)]
struct State {
    confirmed: bool,
    issued: Vec<String>,
    scrobbles: Vec<Value>,
}

pub struct MockTracking {
    server: Server,
    state: Arc<Mutex<State>>,
}

impl MockTracking {
    pub async fn start() -> MockTracking {
        let state = Arc::new(Mutex::new(State::default()));
        let s = state.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let (status, body) = answer(&req, &mut s.lock().unwrap());
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
        MockTracking {
            server: Server::start(handler).await,
            state,
        }
    }

    pub fn base(&self) -> String {
        self.server.url("")
    }

    pub fn confirm(&self) {
        self.state.lock().unwrap().confirmed = true;
    }

    pub fn reset(&self) {
        self.state.lock().unwrap().confirmed = false;
    }

    /// The scrobble bodies received, in order.
    pub fn scrobbles(&self) -> Vec<Value> {
        self.state.lock().unwrap().scrobbles.clone()
    }
}

fn issue(s: &mut State) -> Value {
    let t = format!("token{}", s.issued.len() + 1);
    s.issued.push(t.clone());
    json!({ "access_token": t, "refresh_token": format!("refresh{}", s.issued.len()), "expires_in": 86_400,
            "token_type": "bearer" })
}

fn answer(req: &Request, s: &mut State) -> (u16, Value) {
    let body: Value = serde_json::from_str(&req.body).unwrap_or(Value::Null);
    // Trakt sends JSON, Simkl a form (split into `query` by the server).
    let field = |k: &str| {
        body[k]
            .as_str()
            .map(str::to_string)
            .or_else(|| req.param(k).map(str::to_string))
    };
    let client_ok = field("client_id").as_deref() == Some(CLIENT_ID)
        || req.header("trakt-api-key") == Some(CLIENT_ID);
    match req.path.as_str() {
        "/oauth/device/code" | "/oauth2/device" if client_ok => (
            200,
            json!({ "device_code": "dev1", "user_code": "ABCD1234", "verification_url": "https://trakt.tv/activate",
                    "verification_uri": "https://simkl.com/pin", "expires_in": 600, "interval": 5 }),
        ),
        "/oauth/device/token" if field("client_secret").as_deref() == Some(SECRET) => {
            if s.confirmed {
                (200, issue(s))
            } else {
                (400, Value::Null)
            }
        }
        "/oauth/token" if field("grant_type").as_deref() == Some("refresh_token") => {
            (200, issue(s))
        }
        "/oauth2/token" if client_ok => match field("grant_type").as_deref() {
            Some("refresh_token") => (200, issue(s)),
            _ if s.confirmed => (200, issue(s)),
            _ => (400, json!({ "error": "authorization_pending" })),
        },
        p if p.starts_with("/scrobble/") => {
            let auth = req.header("authorization").unwrap_or_default();
            if !s.issued.iter().any(|t| auth == format!("Bearer {t}")) {
                return (401, Value::Null);
            }
            s.scrobbles.push(body.clone());
            (
                201,
                json!({ "action": p.trim_start_matches("/scrobble/"), "progress": body["progress"] }),
            )
        }
        _ => (400, json!({ "error": "invalid_client" })),
    }
}
