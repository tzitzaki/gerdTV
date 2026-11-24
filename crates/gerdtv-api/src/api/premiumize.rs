//! Bridge surface for the Premiumize cloud (logic: gerdtv_core::premiumize). The app keeps the token in its secure
//! storage and passes it with every call; nothing here stores it.

use gerdtv_core::premiumize as core;

/// A cloud folder or file; `playable` files play from `link`.
pub struct PmEntry {
    pub id: String,
    pub name: String,
    pub folder: bool,
    pub size: u64,
    pub playable: bool,
    pub link: String,
}

pub struct PmTransfer {
    pub id: String,
    pub name: String,
    pub status: String,
    pub progress: f64,
    pub message: String,
    pub folder_id: String,
    pub file_id: String,
}

pub struct PmDeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub interval: u32,
    pub expires_in: u32,
}

/// One poll: `token` once confirmed; `failed` names why it stopped (refused, expired); neither: ask again,
/// `slow_down`: 5 s later than planned.
pub struct PmPoll {
    pub token: Option<String>,
    pub failed: Option<String>,
    pub slow_down: bool,
}

fn err(e: core::PmError) -> String {
    e.to_string()
}

/// Checks a key or token; Ok when Premiumize accepts it.
pub async fn pm_check(token: String) -> Result<(), String> {
    core::Premiumize::new(core::BASE, &token)
        .account()
        .await
        .map(|_| ())
        .map_err(err)
}

/// A folder's content (`id` None: the root).
pub async fn pm_folder(token: String, id: Option<String>) -> Result<Vec<PmEntry>, String> {
    Ok(core::Premiumize::new(core::BASE, &token)
        .folder(id.as_deref())
        .await
        .map_err(err)?
        .into_iter()
        .map(|e| PmEntry {
            playable: core::playable(&e),
            id: e.id,
            name: e.name,
            folder: e.folder,
            size: e.size,
            link: e.link,
        })
        .collect())
}

pub async fn pm_transfers(token: String) -> Result<Vec<PmTransfer>, String> {
    Ok(core::Premiumize::new(core::BASE, &token)
        .transfers()
        .await
        .map_err(err)?
        .into_iter()
        .map(|t| PmTransfer {
            id: t.id,
            name: t.name,
            status: t.status,
            progress: t.progress,
            message: t.message,
            folder_id: t.folder_id,
            file_id: t.file_id,
        })
        .collect())
}

pub async fn pm_device_start(client_id: String) -> Result<PmDeviceCode, String> {
    let c = core::device_start(core::BASE, &client_id)
        .await
        .map_err(err)?;
    Ok(PmDeviceCode {
        device_code: c.device_code,
        user_code: c.user_code,
        verification_uri: c.verification_uri,
        interval: c.interval,
        expires_in: c.expires_in,
    })
}

pub async fn pm_device_poll(client_id: String, device_code: String) -> Result<PmPoll, String> {
    let p = core::device_poll(core::BASE, &client_id, &device_code)
        .await
        .map_err(err)?;
    Ok(match p {
        core::DevicePoll::Token(t) => PmPoll {
            token: Some(t),
            failed: None,
            slow_down: false,
        },
        core::DevicePoll::Failed(f) => PmPoll {
            token: None,
            failed: Some(f),
            slow_down: false,
        },
        core::DevicePoll::SlowDown => PmPoll {
            token: None,
            failed: None,
            slow_down: true,
        },
        core::DevicePoll::Pending => PmPoll {
            token: None,
            failed: None,
            slow_down: false,
        },
    })
}
