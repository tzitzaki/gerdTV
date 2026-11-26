//! Bridge surface for Google Cast (logic: gerdtv_core::cast). Started from the library (`Library::cast_start`), so
//! the provider URL with its login never crosses into Dart.

use gerdtv_core::cast as core;

/// A Cast device found on the network (iOS finds them with Apple's Bonjour browser and passes them in the same way).
pub struct CastDeviceInfo {
    pub name: String,
    pub host: String,
    pub port: u16,
}

impl CastDeviceInfo {
    pub(crate) fn device(&self) -> Result<core::Device, String> {
        Ok(core::Device {
            name: self.name.clone(),
            ip: self
                .host
                .parse()
                .map_err(|_| format!("not an address: {}", self.host))?,
            port: self.port,
        })
    }
}

/// Devices answering on the network within `secs` (mDNS; not on iOS, see [CastDeviceInfo]).
pub async fn cast_discover(secs: u32) -> Result<Vec<CastDeviceInfo>, String> {
    Ok(core::discover(secs as u64)
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|d| CastDeviceInfo {
            name: d.name,
            host: d.ip.to_string(),
            port: d.port,
        })
        .collect())
}

/// A running cast (gerdtv_core::cast::Casting).
pub struct CastHandle(pub(crate) core::Casting);

impl CastHandle {
    /// "provider" or "gerdtv": which route plays.
    #[flutter_rust_bridge::frb(sync)]
    pub fn route(&self) -> String {
        self.0.route.to_string()
    }

    pub async fn pause(&self, pause: bool) -> Result<(), String> {
        self.0.pause(pause).await.map_err(|e| e.to_string())
    }

    /// 0 … 1, the device's own volume.
    pub async fn set_volume(&self, level: f64) -> Result<(), String> {
        self.0
            .set_volume(level as f32)
            .await
            .map_err(|e| e.to_string())
    }

    /// False once the device stopped it or the connection is gone.
    pub async fn playing(&self) -> bool {
        self.0.playing().await
    }

    pub async fn stop(&self) {
        self.0.stop().await
    }
}
