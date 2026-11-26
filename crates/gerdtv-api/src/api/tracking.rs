//! Bridge surface for Trakt and Simkl (logic: gerdtv_core::tracking). The app passes gerdTV's client id (and
//! Trakt's secret) from its build defines and the user's token JSON from its secure storage; a call that had to
//! refresh the token returns the new JSON for the app to store.

use gerdtv_core::tracking as core;

/// "trakt" or "simkl".
fn client(service: &str, client_id: String, client_secret: String) -> Result<core::Client, String> {
    let service = match service {
        "trakt" => core::Service::Trakt,
        "simkl" => core::Service::Simkl,
        other => return Err(format!("unknown service {other}")),
    };
    Ok(core::Client {
        service,
        base: service.base().to_string(),
        client_id,
        client_secret,
    })
}

pub struct TrackDeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub interval: u32,
    pub expires_in: u32,
}

/// One poll: `token` (the JSON to store) once confirmed, `failed` when it stopped, `slow_down` to wait 5 s more.
pub struct TrackPoll {
    pub token: Option<String>,
    pub failed: Option<String>,
    pub slow_down: bool,
}

pub async fn track_device_start(
    service: String,
    client_id: String,
    client_secret: String,
) -> Result<TrackDeviceCode, String> {
    let c = core::device_start(&client(&service, client_id, client_secret)?)
        .await
        .map_err(|e| e.to_string())?;
    Ok(TrackDeviceCode {
        device_code: c.device_code,
        user_code: c.user_code,
        verification_uri: c.verification_uri,
        interval: c.interval,
        expires_in: c.expires_in,
    })
}

pub async fn track_device_poll(
    service: String,
    client_id: String,
    client_secret: String,
    device_code: String,
) -> Result<TrackPoll, String> {
    let p = core::device_poll(&client(&service, client_id, client_secret)?, &device_code)
        .await
        .map_err(|e| e.to_string())?;
    let (token, failed, slow_down) = match p {
        core::Poll::Token(t) => (Some(t.to_json()), None, false),
        core::Poll::Failed(f) => (None, Some(f), false),
        core::Poll::SlowDown => (None, None, true),
        core::Poll::Pending => (None, None, false),
    };
    Ok(TrackPoll {
        token,
        failed,
        slow_down,
    })
}

/// What plays, from the item's row: a movie by `title` and `year`, an episode by `show`, `season` and `number`.
/// Names are cleaned of the panel's decorations here.
pub struct TrackItem {
    pub movie: bool,
    pub name: String,
    pub year: Option<u32>,
    pub show: String,
    pub season: u32,
    pub number: u32,
    /// TMDB's id of the movie, or of an episode's series, when gerdTV knows it.
    pub tmdb: Option<u64>,
}

/// Scrobbles `action` ("start", "pause", "stop") at `progress` (0–100). Returns the token JSON when it was
/// refreshed (store it), else None.
pub async fn track_scrobble(
    service: String,
    client_id: String,
    client_secret: String,
    token: String,
    action: String,
    item: TrackItem,
    progress: f64,
) -> Result<Option<String>, String> {
    let c = client(&service, client_id, client_secret)?;
    let mut t =
        core::Token::from_json(&token).ok_or("the stored token can't be read: link again")?;
    let fresh = core::refresh(&c, &t).await.map_err(|e| e.to_string())?;
    if let Some(n) = &fresh {
        t = n.clone();
    }
    let action = match action.as_str() {
        "start" => core::Action::Start,
        "pause" => core::Action::Pause,
        _ => core::Action::Stop,
    };
    let w = watching(item);
    core::scrobble(&c, &t, action, &w, progress)
        .await
        .map_err(|e| e.to_string())?;
    Ok(fresh.map(|n| n.to_json()))
}

/// Tells Simkl a movie or episode was marked as watched by hand (`watched`) or unmarked. Returns the token JSON when
/// it was refreshed, else None.
pub async fn simkl_history(
    client_id: String,
    token: String,
    item: TrackItem,
    watched: bool,
) -> Result<Option<String>, String> {
    let c = client("simkl", client_id, String::new())?;
    let mut t =
        core::Token::from_json(&token).ok_or("the stored token can't be read: link again")?;
    let fresh = core::refresh(&c, &t).await.map_err(|e| e.to_string())?;
    if let Some(n) = &fresh {
        t = n.clone();
    }
    core::simkl_history(&c, &t, &watching(item), watched)
        .await
        .map_err(|e| e.to_string())?;
    Ok(fresh.map(|n| n.to_json()))
}

/// The core's view of an item (titles cleaned of the panel's decorations).
fn watching(item: TrackItem) -> core::Watching {
    if item.movie {
        let (title, year) = core::clean_title(&item.name);
        core::Watching::Movie {
            title,
            year: item.year.or(year),
            tmdb: item.tmdb,
        }
    } else {
        core::Watching::Episode {
            show: core::clean_title(&item.show).0,
            season: item.season,
            number: item.number,
            tmdb: item.tmdb,
        }
    }
}
