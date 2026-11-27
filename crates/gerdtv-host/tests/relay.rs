//! New, because nothing owns pairing across networks: two devices that can't reach each other on the LAN pair by
//! code and later sync as remembered peers through the host's relay (real HTTP, the host's own server), and what the
//! host stores never opens without the code. The handshake and merge rules themselves are pairing.rs's tests.

use gerdtv_core::pairing::{
    self, Device, Event, Listener, Local, LocalSecrets, Peer, connect_code, connect_peer,
};
use gerdtv_core::relay::Relay;
use gerdtv_host::{Config, Host, HostFile, serve};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn side(id: &str, tmdb: Option<&str>) -> Local {
    let dir = std::env::temp_dir().join(format!("gerdtv-relay-{id}-{}", pairing::new_device_id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut secrets = LocalSecrets::default();
    if let Some(k) = tmdb {
        secrets.app_keys.insert("tmdb".into(), k.into());
        secrets.keys_updated_at = 5;
    }
    Local {
        dir,
        me: Device {
            // A real device id: the doorbell's name (hex).
            id: pairing::new_device_id(),
            name: id.into(),
            platform: "linux".into(),
        },
        secrets,
        peers: vec![],
        port: None,
        web: None,
    }
}

/// The host's web server on a free local port; its front address is what the devices use as the relay.
async fn relay_host() -> String {
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let front = format!("http://127.0.0.1:{port}");
    let cfg = Config {
        dir: std::env::temp_dir().join(format!("gerdtv-relay-host-{}", pairing::new_device_id())),
        front: front.clone(),
        player: "http://player.example.invalid".into(),
        listen: format!("127.0.0.1:{port}"),
        proxy: None,
    };
    let host = Host::new(cfg, HostFile::default());
    tokio::spawn(serve(host));
    // Until it accepts.
    for _ in 0..50 {
        if tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_ok()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    front
}

async fn applied(rx: &mut tokio::sync::mpsc::UnboundedReceiver<Event>) -> Box<pairing::Applied> {
    loop {
        match tokio::time::timeout(Duration::from_secs(20), rx.recv())
            .await
            .unwrap()
            .unwrap()
        {
            Event::Applied(a) => return a,
            Event::NewCode(_) => continue,
            Event::Failed(e) => panic!("{e}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn pair_by_code_then_sync_through_the_relay() {
    let web = relay_host().await;
    let tv = side("tv", None);
    let tv_me = tv.me.clone();
    let tv_local = Arc::new(Mutex::new(tv));
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let listener = Listener::start(tv_local.clone(), tx).await.unwrap();
    let relay = Relay {
        web: web.clone(),
        bell: tv_me.id.clone(),
    };
    listener.set_relay(Some(relay.clone()));
    let code = listener.new_code();

    // The phone has no LAN address for the TV (another network): only the QR's relay.
    let phone = side("phone", Some("tmdb-key"));
    let link = pairing::qr_text("", &code, Some(&relay));
    let link = pairing::parse_pair_link(&link).unwrap();
    let conn = connect_code("", &code, &phone.me, None, link.relay.as_ref())
        .await
        .unwrap();
    assert_eq!(
        conn.peer, tv_me,
        "who answered shows before anything is sent"
    );
    let mine = conn.exchange(&phone).await.unwrap();
    let theirs = applied(&mut rx).await;
    assert_eq!(theirs.peer, phone.me);
    assert_eq!(
        theirs.app_keys.as_ref().map(|(k, _)| k["tmdb"].clone()),
        Some("tmdb-key".to_string()),
        "the phone's key reached the TV"
    );
    assert_eq!(
        theirs.peer_addr, None,
        "no LAN address learnt through the relay"
    );

    // Remembered from now on: a sync by the shared key, no code, again only through the relay.
    let key = mine.new_key.clone().unwrap();
    tv_local.lock().unwrap().peers.push(Peer {
        device: phone.me.clone(),
        key: key.clone(),
        addr: String::new(),
        web: String::new(),
    });
    listener.clear_code();
    let tv_peer = Peer {
        device: tv_me.clone(),
        key,
        addr: String::new(),
        web: String::new(),
    };
    let again = connect_peer("", &phone.me, None, &tv_peer, Some(&relay))
        .await
        .unwrap();
    again.exchange(&phone).await.unwrap();
    assert_eq!(applied(&mut rx).await.peer, phone.me);

    // A stranger ringing with a made-up key gets nothing.
    let stranger = Peer {
        key: "00".repeat(32),
        ..tv_peer
    };
    let mut other = side("other", None);
    other.me.id = phone.me.id.clone();
    assert!(
        connect_peer("", &other.me, None, &stranger, Some(&relay))
            .await
            .is_err()
    );
}
