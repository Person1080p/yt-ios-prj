//! Account connections, preferences and system status.

use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{
    error::{ApiResult, AppError},
    routes::base_url,
    services::{
        playback::{self, PlaybackEvent},
        plex::{PlexPin, PlexServer},
        tailscale::{self, TailscaleInfo},
        ytauth,
        ytmusic::{ACCOUNT_KEY, COOKIE_SOURCE_KEY, COOKIE_SYNCED_KEY},
    },
    state::SharedState,
};

fn ok() -> Json<Value> {
    Json(json!({ "ok": true }))
}

// ---- status -----------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    ytdlp: Value,
    ytmusic: Value,
    plex: Value,
    lastfm: Value,
    spotify: Value,
    deezer: Value,
    prefs: Prefs,
    tailscale: TailscaleInfo,
    public_url: String,
}

pub async fn status(State(st): State<SharedState>, headers: HeaderMap) -> ApiResult<Status> {
    let (ytdlp_path, ytdlp_version) = match st.ytdlp.binary().await {
        Ok(p) => (Some(p.display().to_string()), st.ytdlp.version().await.ok()),
        Err(_) => (None, None),
    };
    let plex = st.plex.server().await;
    let lastfm_session = st.lastfm.session().await;

    // Host-mode tailscale status is cheap enough to refresh on demand.
    let ts = {
        let cur = st.tailscale.lock().await.clone();
        if cur.mode == "embedded" {
            cur
        } else {
            let fresh = tailscale::host_status(st.cfg.bind).await;
            *st.tailscale.lock().await = fresh.clone();
            fresh
        }
    };

    Ok(Json(Status {
        ytdlp: json!({ "path": ytdlp_path, "version": ytdlp_version }),
        ytmusic: json!({
            "authenticated": st.yt.is_authenticated().await,
            "activeNow": st.yt.signed_in_now().await,
            "source": st.db.get_setting(COOKIE_SOURCE_KEY).await?,
            "account": st.db.get_setting(ACCOUNT_KEY).await?,
            "syncedAt": st.db.get_setting(COOKIE_SYNCED_KEY).await?.and_then(|s| s.parse::<i64>().ok()),
        }),
        plex: json!({
            "connected": plex.is_some(),
            "url": plex.map(|(u, _)| u),
            "loggedIn": st.db.get_setting("plex.account_token").await?.is_some(),
        }),
        lastfm: json!({
            "configured": st.lastfm.keys().await.is_some(),
            "keysFromEnv": st.cfg.lastfm_api_key.is_some(),
            "connected": lastfm_session.is_some(),
            "username": lastfm_session.map(|(_, u)| u),
        }),
        spotify: json!({
            "configured": st.cfg.spotify_client_id.is_some(),
            "connected": st.db.get_setting("spotify.refresh_token").await?.is_some(),
        }),
        deezer: json!({ "userId": st.db.get_setting("deezer.user_id").await? }),
        prefs: load_prefs(&st).await,
        tailscale: ts,
        public_url: base_url(&st, &headers).await,
    }))
}

pub async fn update_ytdlp(State(st): State<SharedState>) -> ApiResult<Value> {
    let out = st.ytdlp.update().await?;
    Ok(Json(json!({ "output": out, "version": st.ytdlp.version().await.ok() })))
}

// ---- preferences ----------------------------------------------------------------

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Prefs {
    prefer_plex: bool,
    scrobble: bool,
    report_youtube: bool,
}

async fn load_prefs(st: &SharedState) -> Prefs {
    Prefs {
        prefer_plex: st.db.get_bool("prefs.prefer_plex", true).await,
        scrobble: st.db.get_bool("prefs.scrobble", true).await,
        report_youtube: st.db.get_bool("prefs.report_youtube", true).await,
    }
}

pub async fn set_prefs(State(st): State<SharedState>, Json(p): Json<Prefs>) -> ApiResult<Prefs> {
    st.db.set_setting("prefs.prefer_plex", if p.prefer_plex { "1" } else { "0" }).await?;
    st.db.set_setting("prefs.scrobble", if p.scrobble { "1" } else { "0" }).await?;
    st.db.set_setting("prefs.report_youtube", if p.report_youtube { "1" } else { "0" }).await?;
    Ok(Json(load_prefs(&st).await))
}

// ---- YouTube Music ----------------------------------------------------------------

#[derive(Deserialize)]
pub struct CookieBody {
    cookie: String,
}

pub async fn set_yt_cookie(State(st): State<SharedState>, Json(b): Json<CookieBody>) -> ApiResult<Value> {
    // Accept either the raw header value or a copied "cookie: ..." line.
    let cookie = b.cookie.trim().trim_start_matches("Cookie:").trim_start_matches("cookie:").trim().to_string();
    if !cookie.contains("SAPISID") {
        return Err(AppError::bad("Cookie must contain SAPISID / __Secure-3PAPISID (copy it from a logged-in music.youtube.com request)"));
    }
    // Only keep it if YouTube actually signs us in with it.
    let account = ytauth::verify(&st, &cookie).await.map_err(|e| AppError::bad(format!("{e:#}")))?;
    ytauth::save(&st, &cookie, "manual").await?;
    st.db.set_setting(ACCOUNT_KEY, &account).await?;
    Ok(Json(json!({ "ok": true, "account": account })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportBrowserBody {
    /// Specific browser (`firefox`, `chrome`, …); omitted = try them all.
    #[serde(default)]
    browser: Option<String>,
    #[serde(default = "yes")]
    keep_in_sync: bool,
}

fn yes() -> bool {
    true
}

/// Sign in by importing the YouTube session from a browser on the server machine.
pub async fn import_yt_browser(State(st): State<SharedState>, Json(b): Json<ImportBrowserBody>) -> ApiResult<Value> {
    let browser = b.browser.filter(|s| !s.is_empty());
    let (found, account) = ytauth::import(&st, browser.as_deref(), b.keep_in_sync)
        .await
        .map_err(|e| AppError::bad(format!("{e:#}")))?;
    Ok(Json(json!({ "ok": true, "browser": found, "account": account })))
}

pub async fn sync_yt_browser(State(st): State<SharedState>) -> ApiResult<Value> {
    let synced = ytauth::sync_once(&st).await.map_err(|e| AppError::bad(format!("{e:#}")))?;
    Ok(Json(json!({ "ok": true, "synced": synced })))
}

pub async fn delete_yt_cookie(State(st): State<SharedState>) -> ApiResult<Value> {
    st.db.delete_settings("ytmusic.cookie").await?; // cookie, source, sync time, account
    Ok(ok())
}

// ---- Last.fm --------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LastfmKeys {
    api_key: String,
    api_secret: String,
}

pub async fn set_lastfm_keys(State(st): State<SharedState>, Json(b): Json<LastfmKeys>) -> ApiResult<Value> {
    st.db.set_setting("lastfm.api_key", b.api_key.trim()).await?;
    st.db.set_setting("lastfm.api_secret", b.api_secret.trim()).await?;
    Ok(ok())
}

#[derive(Serialize)]
pub struct UrlResponse {
    url: String,
}

#[derive(Deserialize)]
pub struct LastfmLoginQuery {
    callback: String,
}

/// Last.fm sends the user back to `callback?token=...` (a page route in the web app).
pub async fn lastfm_login(State(st): State<SharedState>, Query(q): Query<LastfmLoginQuery>) -> ApiResult<UrlResponse> {
    Ok(Json(UrlResponse { url: st.lastfm.auth_url(&q.callback).await.map_err(|e| AppError::NotConfigured(e.to_string()))? }))
}

#[derive(Deserialize)]
pub struct LastfmSessionBody {
    token: String,
}

pub async fn lastfm_session(State(st): State<SharedState>, Json(b): Json<LastfmSessionBody>) -> ApiResult<Value> {
    let user = st.lastfm.complete_auth(&b.token).await.map_err(|e| AppError::bad(format!("{e:#}")))?;
    Ok(Json(json!({ "ok": true, "username": user })))
}

pub async fn lastfm_disconnect(State(st): State<SharedState>) -> ApiResult<Value> {
    st.lastfm.disconnect().await?;
    Ok(ok())
}

// ---- Plex -----------------------------------------------------------------------

pub async fn plex_pin(State(st): State<SharedState>) -> ApiResult<PlexPin> {
    Ok(Json(st.plex.start_pin().await?))
}

pub async fn plex_pin_check(State(st): State<SharedState>, Path(id): Path<i64>) -> ApiResult<Value> {
    Ok(Json(json!({ "authorized": st.plex.check_pin(id).await? })))
}

pub async fn plex_servers(State(st): State<SharedState>) -> ApiResult<Vec<PlexServer>> {
    Ok(Json(st.plex.servers().await?))
}

#[derive(Deserialize)]
pub struct PlexServerBody {
    url: String,
    token: String,
}

pub async fn plex_set_server(State(st): State<SharedState>, Json(b): Json<PlexServerBody>) -> ApiResult<Value> {
    let id = st.plex.set_server(&b.url, &b.token).await.map_err(|e| AppError::bad(format!("{e:#}")))?;
    Ok(Json(json!({ "ok": true, "machineIdentifier": id })))
}

pub async fn plex_disconnect(State(st): State<SharedState>) -> ApiResult<Value> {
    st.plex.disconnect().await?;
    Ok(ok())
}

// ---- Spotify ----------------------------------------------------------------------

pub async fn spotify_disconnect(State(st): State<SharedState>) -> ApiResult<Value> {
    st.db.delete_settings("spotify.").await?;
    Ok(ok())
}

// ---- playback reports ---------------------------------------------------------------

pub async fn playback_event(State(st): State<SharedState>, Json(ev): Json<PlaybackEvent>) -> ApiResult<Value> {
    playback::handle(&st, ev).await?;
    Ok(ok())
}
