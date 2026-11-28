//! Pairing and syncing across networks (owner decision): when two devices can't reach each other on the local
//! network, they meet at the user's own gerdTV host, which forwards pairing.rs's frames without being able to read
//! them (the same SPAKE2 handshake and sealed frames as on the LAN; the host sees what a LAN eavesdropper would).
//! The LAN stays first; the relay is only the fallback (pairing.rs `connect`).
//!
//! How it fits together:
//! - The host keeps **mailboxes** in memory ([Mailboxes], served by gerdtv-host at `{front}/relay/<key>`): `POST`
//!   drops one message into a box, `GET` takes the next one, waiting up to [POLL_WAIT] for it (a long poll, because
//!   the host speaks plain HTTP behind the user's tunnel, no WebSockets). Keys: `bell/<device id>` and
//!   `s/<session>/<side>` (side `c` = the connector's inbox, `l` = the listener's).
//! - A listening device keeps polling its **doorbell** `bell/<its device id>` while it listens ([crate::pairing::
//!   Listener::set_relay]). A connector rings it with a fresh random session id, then both talk through the session's
//!   two boxes ([RelayPipe]), frame by frame, exactly as over TCP.
//! - Which host: the app's one relay address (typed, a paired host's, or a host found on the network by mDNS); a
//!   pairing QR carries it, so a phone that doesn't know the host yet can still use it.
//!
//! Abuse limits (the front is public and pairing is unauthenticated until SPAKE2 is done): at most [MAX_BOXES]
//! boxes, [MAX_QUEUE] messages per box, [MAX_BYTES] in all, a message at most pairing's largest frame, and a box
//! untouched for [BOX_TTL] is dropped. A full host answers 503 and the devices report it.
//! Debugging: "the relay answered HTTP 503" = the host's limits are reached (or someone floods it); a pairing that
//! waits and then times out usually means the other device isn't polling: it has no relay address, or another one.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::Notify;

/// How long the host holds a `GET` open waiting for a message (below the tunnel's own limit of 100 s).
pub const POLL_WAIT: Duration = Duration::from_secs(25);
/// A box nobody touched for this long is dropped (a code works 10 minutes; a session's steps are much faster).
pub const BOX_TTL: Duration = Duration::from_secs(10 * 60);
pub const MAX_BOXES: usize = 256;
pub const MAX_QUEUE: usize = 16;
/// The largest message: pairing's largest frame (a profile's user data).
pub const MAX_MESSAGE: usize = 32 << 20;
pub const MAX_BYTES: usize = 96 << 20;

/// Whether `key` is a mailbox name the host accepts: `bell/<id>` or `s/<session>/<c|l>`, ids 16 to 64 hex digits.
pub fn valid_key(key: &str) -> bool {
    let id = |s: &str| (16..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit());
    match key.split('/').collect::<Vec<_>>()[..] {
        ["bell", d] => id(d),
        ["s", s, "c" | "l"] => id(s),
        _ => false,
    }
}

/// Why a message was refused.
#[derive(Debug, PartialEq)]
pub enum Refused {
    /// Not a mailbox name (404).
    BadKey,
    /// Too big, or the host's limits are reached (503).
    Full,
}

struct Box_ {
    queue: VecDeque<Vec<u8>>,
    touched: Instant,
}

/// The host's side: the mailboxes, in memory (a host restart drops them; the devices just try again).
#[derive(Default)]
pub struct Mailboxes {
    boxes: Mutex<HashMap<String, Box_>>,
    /// Woken on every new message; each waiting poll checks its own box again.
    arrived: Notify,
}

impl Mailboxes {
    /// Drops boxes nobody touched for [BOX_TTL].
    fn purge(boxes: &mut HashMap<String, Box_>) {
        boxes.retain(|_, b| b.touched.elapsed() < BOX_TTL);
    }

    /// Adds `message` to box `key`.
    pub fn post(&self, key: &str, message: Vec<u8>) -> Result<(), Refused> {
        if !valid_key(key) {
            return Err(Refused::BadKey);
        }
        let mut boxes = self.boxes.lock().unwrap();
        Self::purge(&mut boxes);
        let bytes: usize = boxes.values().flat_map(|b| &b.queue).map(Vec::len).sum();
        let new_box = !boxes.contains_key(key);
        if message.len() > MAX_MESSAGE
            || bytes + message.len() > MAX_BYTES
            || (new_box && boxes.len() >= MAX_BOXES)
        {
            return Err(Refused::Full);
        }
        let b = boxes.entry(key.to_string()).or_insert_with(|| Box_ {
            queue: VecDeque::new(),
            touched: Instant::now(),
        });
        if b.queue.len() >= MAX_QUEUE {
            return Err(Refused::Full);
        }
        b.queue.push_back(message);
        b.touched = Instant::now();
        drop(boxes);
        self.arrived.notify_waiters();
        Ok(())
    }

    /// Takes the next message of box `key`, waiting up to `wait` for one; None when none came.
    pub async fn poll(&self, key: &str, wait: Duration) -> Result<Option<Vec<u8>>, Refused> {
        if !valid_key(key) {
            return Err(Refused::BadKey);
        }
        let end = tokio::time::Instant::now() + wait;
        loop {
            // Registered before looking, so a message posted in between still wakes this poll.
            let arrived = self.arrived.notified();
            tokio::pin!(arrived);
            arrived.as_mut().enable();
            {
                let mut boxes = self.boxes.lock().unwrap();
                if let Some(b) = boxes.get_mut(key) {
                    b.touched = Instant::now();
                    if let Some(m) = b.queue.pop_front() {
                        return Ok(Some(m));
                    }
                }
            }
            if tokio::time::timeout_at(end, arrived).await.is_err() {
                return Ok(None);
            }
        }
    }
}

// ---- the devices' side ----

/// Where a device meets the other one: the host's front address and the listener's doorbell (its device id).
#[derive(Debug, Clone, PartialEq)]
pub struct Relay {
    pub web: String,
    pub bell: String,
}

fn io(e: impl std::fmt::Display) -> std::io::Error {
    std::io::Error::other(e.to_string())
}

fn client() -> std::io::Result<reqwest::Client> {
    crate::xtream::ensure_tls_provider();
    reqwest::Client::builder()
        // Above the host's long poll, and enough for a big profile's message through the tunnel.
        .timeout(POLL_WAIT + Duration::from_secs(60))
        .build()
        .map_err(|e| io(e.without_url()))
}

fn url(web: &str, key: &str) -> String {
    format!("{}/relay/{key}", web.trim_end_matches('/'))
}

async fn post(c: &reqwest::Client, web: &str, key: &str, body: Vec<u8>) -> std::io::Result<()> {
    let res = c
        .post(url(web, key))
        .header("content-type", "application/octet-stream")
        .body(body)
        .send()
        .await
        .map_err(|e| io(e.without_url()))?;
    if !res.status().is_success() {
        return Err(io(format!(
            "the relay answered HTTP {}",
            res.status().as_u16()
        )));
    }
    Ok(())
}

/// One long poll: Some(message), or None when the host's wait ended without one.
async fn get(c: &reqwest::Client, web: &str, key: &str) -> std::io::Result<Option<Vec<u8>>> {
    let res = c
        .get(url(web, key))
        .send()
        .await
        .map_err(|e| io(e.without_url()))?;
    match res.status().as_u16() {
        200 => Ok(Some(
            res.bytes().await.map_err(|e| io(e.without_url()))?.to_vec(),
        )),
        204 => Ok(None),
        s => Err(io(format!("the relay answered HTTP {s}"))),
    }
}

/// A listener's doorbell: waits (one long poll) for a connector's session id.
pub async fn wait_bell(web: &str, bell: &str) -> std::io::Result<Option<String>> {
    let c = client()?;
    let rung = get(&c, web, &format!("bell/{bell}")).await?;
    Ok(rung.and_then(|s| String::from_utf8(s).ok()))
}

/// One side of a relayed session: frames go into the other side's box and come from this side's.
pub struct RelayPipe {
    client: reqwest::Client,
    web: String,
    inbox: String,
    outbox: String,
}

impl RelayPipe {
    /// The connector's side: rings `relay.bell` with a fresh session.
    pub async fn ring(relay: &Relay) -> std::io::Result<RelayPipe> {
        let session = crate::pairing::hex(&crate::pairing::random::<16>());
        let client = client()?;
        post(
            &client,
            &relay.web,
            &format!("bell/{}", relay.bell),
            session.clone().into_bytes(),
        )
        .await?;
        Ok(Self::new(client, &relay.web, &session, false))
    }

    /// The listener's side of a session its doorbell announced.
    pub fn answer(web: &str, session: &str) -> std::io::Result<RelayPipe> {
        Ok(Self::new(client()?, web, session, true))
    }

    fn new(client: reqwest::Client, web: &str, session: &str, listener: bool) -> RelayPipe {
        let (me, other) = if listener { ("l", "c") } else { ("c", "l") };
        RelayPipe {
            client,
            web: web.to_string(),
            inbox: format!("s/{session}/{me}"),
            outbox: format!("s/{session}/{other}"),
        }
    }

    pub async fn send(&mut self, frame: &[u8]) -> std::io::Result<()> {
        post(&self.client, &self.web, &self.outbox, frame.to_vec()).await
    }

    /// Tells the other side this one gave up (an empty frame: no real frame is empty), so it doesn't wait for a
    /// frame that never comes, as a closed TCP connection would tell it on the LAN.
    pub async fn close(&mut self) {
        let _ = self.send(&[]).await;
    }

    /// The next frame, polling until one comes (the caller bounds the wait).
    pub async fn receive(&mut self) -> std::io::Result<Vec<u8>> {
        loop {
            match get(&self.client, &self.web, &self.inbox).await? {
                Some(f) if f.is_empty() => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::ConnectionAborted,
                        "the other device ended the connection",
                    ));
                }
                Some(f) => return Ok(f),
                None => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys() {
        let id = "0123456789abcdef";
        for (key, ok) in [
            (format!("bell/{id}"), true),
            (format!("s/{id}/c"), true),
            (format!("s/{id}/l"), true),
            (format!("s/{id}/x"), false),
            ("bell/short".to_string(), false),
            (format!("bell/{id}/extra"), false),
            (format!("other/{id}"), false),
            ("bell/../etc".to_string(), false),
        ] {
            assert_eq!(valid_key(&key), ok, "{key}");
        }
    }

    #[tokio::test]
    async fn a_poll_waits_for_the_message_and_limits_hold() {
        let m = std::sync::Arc::new(Mailboxes::default());
        let key = "bell/0123456789abcdef";
        // Nothing there: the poll ends empty after its wait.
        assert_eq!(m.poll(key, Duration::from_millis(10)).await, Ok(None));
        // A message posted while the poll waits wakes it.
        let waiting = tokio::spawn({
            let m = m.clone();
            async move { m.poll(key, Duration::from_secs(5)).await }
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        m.post(key, b"s1".to_vec()).unwrap();
        assert_eq!(waiting.await.unwrap(), Ok(Some(b"s1".to_vec())));
        // Order is kept; a full box and a bad key are refused.
        for i in 0..MAX_QUEUE {
            m.post(key, vec![i as u8]).unwrap();
        }
        assert_eq!(m.post(key, vec![0]), Err(Refused::Full));
        assert_eq!(m.poll(key, Duration::ZERO).await, Ok(Some(vec![0])));
        assert_eq!(m.post("nope", vec![0]), Err(Refused::BadKey));
        assert_eq!(
            m.post("bell/fedcba9876543210", vec![0; MAX_MESSAGE + 1]),
            Err(Refused::Full)
        );
    }
}
