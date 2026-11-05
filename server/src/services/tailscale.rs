//! Tailscale connectivity.
//!
//! Two modes:
//! * **host** (default): the machine runs `tailscaled`. We read its status so the UI can show the
//!   tailnet URL / QR code; `tailscale serve` provides HTTPS (required for PWA install on phones).
//! * **embedded** (`--features embedded-tailscale`; on by default in such builds): the server joins
//!   the tailnet itself through tsnet (server/tsnet-ffi) — no tailscaled needed on the host. It serves
//!   plain HTTP on tailnet port 80 (WireGuard-encrypted), plus HTTPS on :443 with a Let's Encrypt
//!   cert for its `*.ts.net` name when HTTPS certificates are enabled for the tailnet. Its sign-in
//!   link is shown in the web app (Settings → Connection) until it's authorised.

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TailscaleInfo {
    /// embedded | host | none
    pub mode: String,
    pub online: bool,
    pub dns_name: Option<String>,
    pub ips: Vec<String>,
    /// URL a phone on the tailnet should open.
    pub url: Option<String>,
    pub hint: Option<String>,
    /// tailscaled backend state: NeedsLogin, NeedsMachineAuth, Starting, Running, …
    pub state: Option<String>,
    /// Sign-in link while the server's node is waiting to be authorised.
    pub auth_url: Option<String>,
}

/// Inspect a host tailscaled through the CLI.
pub async fn host_status(bind: std::net::SocketAddr) -> TailscaleInfo {
    let port = bind.port();
    let out = tokio::process::Command::new("tailscale").args(["status", "--json"]).output().await;
    let Ok(out) = out else {
        return TailscaleInfo {
            mode: "none".into(),
            hint: Some("The server isn't on your tailnet: Tailscale isn't installed on this machine and this build has no embedded Tailscale. Rebuild with --features embedded-tailscale (see README), or install Tailscale.".into()),
            ..Default::default()
        };
    };
    let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) else {
        return TailscaleInfo { mode: "none".into(), hint: Some("tailscaled is not running".into()), ..Default::default() };
    };
    let me = &v["Self"];
    let dns = me["DNSName"].as_str().map(|s| s.trim_end_matches('.').to_string()).filter(|s| !s.is_empty());
    let ips: Vec<String> = me["TailscaleIPs"]
        .as_array()
        .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let state = v["BackendState"].as_str().map(String::from);
    let online = state.as_deref() == Some("Running");
    let auth_url = v["AuthURL"].as_str().filter(|s| !s.is_empty()).map(String::from);

    // Is `tailscale serve` proxying HTTPS to us?
    let serving = tokio::process::Command::new("tailscale")
        .args(["serve", "status", "--json"])
        .output()
        .await
        .ok()
        .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
        .map(|s| s.to_string().contains(&format!(":{port}")))
        .unwrap_or(false);

    let (url, hint) = match (&dns, serving) {
        (Some(d), true) => (Some(format!("https://{d}")), None),
        // Without `tailscale serve`, tailnet peers can only reach us if we listen beyond loopback.
        (Some(d), false) => (
            (!bind.ip().is_loopback()).then(|| format!("http://{d}:{port}")),
            Some(format!(
                "Run `tailscale serve --bg {port}` on the server to get https://{d} — browsers only allow installing the PWA (and background audio on iOS) over HTTPS."
            )),
        ),
        _ => (None, Some("Log in with `tailscale up`".into())),
    };
    TailscaleInfo { mode: "host".into(), online, dns_name: dns, ips, url, hint, state, auth_url }
}

#[cfg(feature = "embedded-tailscale")]
pub mod embedded {
    //! The server's own Tailscale node: tailscale.com/tsnet compiled into the binary from
    //! `server/tsnet-ffi` (see build.rs). Go terminates the tailnet listeners — including HTTPS
    //! with the node's `*.ts.net` certificate — and proxies each connection to the local axum
    //! listener, so nothing else in the server needs to know about Tailscale.

    use std::{
        ffi::{c_char, c_int, CStr, CString},
        net::SocketAddr,
        sync::Arc,
        time::Duration,
    };

    use anyhow::{anyhow, Context};
    use serde_json::Value;

    use super::TailscaleInfo;
    use crate::config::TailscaleConfig;

    extern "C" {
        fn ytp_ts_start(dir: *const c_char, hostname: *const c_char, authkey: *const c_char, control_url: *const c_char) -> c_int;
        fn ytp_ts_status() -> *mut c_char;
        fn ytp_ts_login() -> c_int;
        fn ytp_ts_forward(addr: *const c_char, target: *const c_char, tls: c_int) -> c_int;
        fn ytp_ts_last_error() -> *mut c_char;
        fn ytp_ts_free(p: *mut c_char);
    }

    fn take_string(p: *mut c_char) -> Option<String> {
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { ytp_ts_free(p) };
        Some(s)
    }

    fn last_error(what: &str) -> anyhow::Error {
        let msg = take_string(unsafe { ytp_ts_last_error() }).unwrap_or_default();
        anyhow!("tailscale {what}: {msg}")
    }

    fn check(rc: c_int, what: &str) -> anyhow::Result<()> {
        if rc == 0 { Ok(()) } else { Err(last_error(what)) }
    }

    fn start(cfg: &TailscaleConfig) -> anyhow::Result<()> {
        std::fs::create_dir_all(&cfg.state_dir)?;
        let dir = CString::new(cfg.state_dir.to_string_lossy().as_bytes())?;
        let host = CString::new(cfg.hostname.as_str())?;
        let key = CString::new(cfg.authkey.clone().unwrap_or_default())?;
        let control = CString::new("")?; // default control plane
        check(unsafe { ytp_ts_start(dir.as_ptr(), host.as_ptr(), key.as_ptr(), control.as_ptr()) }, "start")
    }

    fn status() -> anyhow::Result<Value> {
        let json = take_string(unsafe { ytp_ts_status() }).ok_or_else(|| last_error("status"))?;
        Ok(serde_json::from_str(&json)?)
    }

    fn forward(addr: &str, target: &str, tls: bool) -> anyhow::Result<()> {
        let a = CString::new(addr)?;
        let t = CString::new(target)?;
        check(unsafe { ytp_ts_forward(a.as_ptr(), t.as_ptr(), tls as c_int) }, &format!("listen {addr}"))
    }

    async fn blocking<T: Send + 'static>(f: impl FnOnce() -> anyhow::Result<T> + Send + 'static) -> anyhow::Result<T> {
        tokio::task::spawn_blocking(f).await?
    }

    fn to_info(v: &Value) -> (TailscaleInfo, bool) {
        let me = &v["Self"];
        let dns = me["DNSName"].as_str().map(|s| s.trim_end_matches('.').to_string()).filter(|s| !s.is_empty());
        let state = v["BackendState"].as_str().map(String::from);
        let https = v["CertDomains"].as_array().is_some_and(|a| !a.is_empty());
        let info = TailscaleInfo {
            mode: "embedded".into(),
            online: state.as_deref() == Some("Running"),
            url: dns.as_ref().map(|d| format!("http://{d}")),
            dns_name: dns,
            ips: me["TailscaleIPs"]
                .as_array()
                .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                .unwrap_or_default(),
            hint: None,
            auth_url: v["AuthURL"].as_str().filter(|s| !s.is_empty()).map(String::from),
            state,
        };
        (info, https)
    }

    /// Join the tailnet and expose the local server (`bind`) on it. Runs for the life of the process.
    /// Progress — state, sign-in link, addresses — is published to `shared` for the web app.
    pub async fn run(cfg: TailscaleConfig, bind: SocketAddr, shared: Arc<tokio::sync::Mutex<TailscaleInfo>>) -> anyhow::Result<()> {
        let has_authkey = cfg.authkey.is_some();
        let hostname = cfg.hostname.clone();
        blocking(move || start(&cfg)).await.context("starting the embedded Tailscale node")?;
        tracing::info!("tailnet: starting node \"{hostname}\"");

        // Wait until the node is authorised and running, publishing the sign-in link meanwhile.
        let mut asked_login = false;
        let mut logged_url: Option<String> = None;
        let (info, https) = loop {
            match blocking(status).await {
                Ok(v) => {
                    let (mut info, https) = to_info(&v);
                    if info.online {
                        break (info, https);
                    }
                    if info.state.as_deref() == Some("NeedsLogin") && info.auth_url.is_none() && !asked_login && !has_authkey {
                        asked_login = true;
                        if let Err(e) = blocking(|| check(unsafe { ytp_ts_login() }, "login")).await {
                            tracing::warn!("tailnet: requesting a sign-in link failed: {e:#}");
                        }
                    }
                    if info.auth_url.is_some() && info.auth_url != logged_url {
                        tracing::warn!("tailnet: sign the server in at {}", info.auth_url.as_deref().unwrap_or_default());
                        logged_url = info.auth_url.clone();
                    }
                    info.hint = Some(match info.state.as_deref() {
                        Some("NeedsLogin") => "Sign the server in to your tailnet using the link (or set TS_AUTHKEY).".into(),
                        Some("NeedsMachineAuth") => "Approve this server in the Tailscale admin console.".into(),
                        _ => "Joining your tailnet…".into(),
                    });
                    *shared.lock().await = info;
                }
                Err(e) => tracing::debug!("tailnet status: {e:#}"),
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        };
        let domain = info.dns_name.clone().context("tailnet node has no DNS name")?;

        // Proxy tailnet connections to the local listener.
        let target = if bind.ip().is_unspecified() { format!("127.0.0.1:{}", bind.port()) } else { bind.to_string() };
        {
            let t = target.clone();
            blocking(move || forward(":80", &t, false)).await?;
        }
        tracing::info!("tailnet: serving http://{domain}");
        let https = https && {
            let t = target.clone();
            match blocking(move || forward(":443", &t, true)).await {
                Ok(()) => {
                    tracing::info!("tailnet: serving https://{domain}");
                    true
                }
                Err(e) => {
                    tracing::warn!("tailnet: HTTPS unavailable ({e:#}); plain HTTP over the tailnet still works");
                    false
                }
            }
        };

        // Keep the published status fresh.
        loop {
            if let Ok(v) = blocking(status).await {
                let (mut i, _) = to_info(&v);
                if https {
                    i.url = Some(format!("https://{domain}"));
                } else {
                    i.hint = Some(format!(
                        "Serving http://{domain} on your tailnet. Enable HTTPS certificates in the Tailscale admin console (then restart) to also get https://{domain}, needed to install the app from that address."
                    ));
                }
                *shared.lock().await = i;
            }
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
    }
}
