pub mod art;
pub mod library;
pub mod music;
pub mod playlists;
pub mod profile;
pub mod queue;
pub mod settings;
pub mod stream;

use std::{convert::Infallible, time::Duration};

use axum::{
    extract::{Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware::{self, Next},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{delete, get, post, put},
    Json, Router,
};
use futures::Stream;
use serde::Deserialize;
use tokio_stream::{wrappers::BroadcastStream, StreamExt};
use tower_http::{
    services::{ServeDir, ServeFile},
    trace::TraceLayer,
};

use crate::state::SharedState;

const AUTH_COOKIE: &str = "ytp_token";

pub fn router(state: SharedState) -> Router {
    let api = Router::new()
        // music
        .route("/home", get(music::home))
        .route("/discover", get(music::discover))
        .route("/search", get(music::search))
        .route("/radio/{video_id}", get(music::radio))
        .route("/playlist/{id}", get(music::playlist))
        .route("/recommendations/{video_id}", get(music::recommendations))
        .route("/tracks/{video_id}", get(music::track))
        .route("/tracks/{video_id}/source", get(stream::source))
        .route("/stream/{video_id}", get(stream::stream))
        .route("/history", get(music::history))
        .route("/playback", post(settings::playback_event))
        // queue
        .route("/queue", get(queue::get))
        .route("/queue/add", post(queue::add))
        .route("/queue/replace", post(queue::replace))
        .route("/queue/radio", post(queue::radio))
        .route("/queue/index", post(queue::set_index))
        .route("/queue/move", post(queue::move_item))
        .route("/queue/remove", post(queue::remove))
        .route("/queue/clear", post(queue::clear))
        .route("/queue/shuffle", post(queue::shuffle))
        .route("/queue/autoplay", post(queue::autoplay))
        // saved playlists
        .route("/playlists", get(playlists::list).post(playlists::create))
        .route("/playlists/{id}", get(playlists::get).put(playlists::update).delete(playlists::delete))
        // library + imports
        .route("/library/liked", get(library::liked).post(library::add))
        .route("/library/liked/{id}", delete(library::remove))
        .route("/library/liked/{id}/match", post(library::set_match))
        .route("/library/ids", get(library::liked_ids))
        .route("/library/rematch", post(library::rematch))
        .route("/import/lastfm", post(library::import_lastfm))
        .route("/tracks/{video_id}/liked", get(library::get_liked).put(library::set_liked))
        .route("/art", get(art::art))
        .route("/import/jobs", get(library::jobs))
        .route("/import/ytmusic", post(library::import_ytmusic))
        .route("/import/spotify", post(library::import_spotify))
        .route("/import/spotify/login", get(library::spotify_login))
        .route("/import/spotify/exchange", post(library::spotify_exchange))
        .route("/import/deezer", post(library::import_deezer))
        .route("/import/text", post(library::import_text))
        .route(
            "/import/file",
            post(library::import_file).layer(axum::extract::DefaultBodyLimit::max(128 * 1024 * 1024)),
        )
        // settings / connections
        .route("/status", get(settings::status))
        .route("/prefs", put(settings::set_prefs))
        .route("/ytdlp/update", post(settings::update_ytdlp))
        .route("/ytmusic/cookie", put(settings::set_yt_cookie).delete(settings::delete_yt_cookie))
        .route("/ytmusic/import-browser", post(settings::import_yt_browser))
        .route("/ytmusic/sync", post(settings::sync_yt_browser))
        .route("/lastfm/keys", put(settings::set_lastfm_keys))
        .route("/lastfm/login", get(settings::lastfm_login))
        .route("/lastfm/session", post(settings::lastfm_session))
        .route("/lastfm", delete(settings::lastfm_disconnect))
        .route("/plex/pin", post(settings::plex_pin))
        .route("/plex/pin/{id}", get(settings::plex_pin_check))
        .route("/plex/servers", get(settings::plex_servers))
        .route("/plex/server", put(settings::plex_set_server))
        .route("/plex", delete(settings::plex_disconnect))
        .route("/spotify", delete(settings::spotify_disconnect))
        .route("/profile", get(profile::get).put(profile::set))
        .route("/profile/fresh/reset", post(profile::reset_fresh))
        .route("/events", get(events))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .route("/auth/login", post(login))
        .route("/auth/check", get(auth_check));

    let web_dir = state.cfg.web_dir.clone();
    let spa = ServeDir::new(&web_dir).precompressed_gzip().fallback(ServeFile::new(web_dir.join("index.html")));

    Router::new()
        .nest("/api", api)
        .fallback_service(spa)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Base URL as seen by the client, for OAuth redirect URIs.
pub async fn base_url(st: &SharedState, headers: &HeaderMap) -> String {
    if let Some(u) = &st.cfg.public_url {
        return u.clone();
    }
    {
        let ts = st.tailscale.lock().await;
        if ts.mode == "embedded" {
            if let Some(u) = &ts.url {
                return u.clone();
            }
        }
    }
    let h = |k: &str| headers.get(k).and_then(|v| v.to_str().ok()).map(String::from);
    let host = h("x-forwarded-host").or_else(|| h("host")).unwrap_or_else(|| st.cfg.bind.to_string());
    let proto = h("x-forwarded-proto").unwrap_or_else(|| {
        // tailscale serve terminates TLS for *.ts.net and forwards plain HTTP.
        if host.ends_with(".ts.net") { "https".into() } else { "http".into() }
    });
    format!("{proto}://{host}")
}

// ---- optional shared-secret auth -------------------------------------------------

fn token_from(req_headers: &HeaderMap, query: Option<&str>) -> Option<String> {
    if let Some(v) = req_headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        if let Some(t) = v.strip_prefix("Bearer ") {
            return Some(t.to_string());
        }
    }
    if let Some(c) = req_headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) {
        for kv in c.split(';') {
            if let Some((k, v)) = kv.trim().split_once('=') {
                if k == AUTH_COOKIE {
                    return Some(v.to_string());
                }
            }
        }
    }
    query?.split('&').find_map(|kv| kv.strip_prefix("token=").map(String::from))
}

fn constant_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn require_auth(State(st): State<SharedState>, req: Request, next: Next) -> Response {
    let Some(expected) = &st.cfg.access_token else { return next.run(req).await };
    // OAuth providers redirect back here without our header, but browsers send the cookie.
    match token_from(req.headers(), req.uri().query()) {
        Some(t) if constant_eq(&t, expected) => next.run(req).await,
        _ => (StatusCode::UNAUTHORIZED, Json(serde_json::json!({ "error": "unauthorized" }))).into_response(),
    }
}

#[derive(Deserialize)]
struct LoginBody {
    token: String,
}

async fn login(State(st): State<SharedState>, Json(b): Json<LoginBody>) -> Response {
    match &st.cfg.access_token {
        Some(expected) if constant_eq(&b.token, expected) => {
            let cookie = format!("{AUTH_COOKIE}={}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax", b.token);
            ([(header::SET_COOKIE, cookie)], Json(serde_json::json!({ "ok": true }))).into_response()
        }
        None => Json(serde_json::json!({ "ok": true })).into_response(),
        _ => (StatusCode::UNAUTHORIZED, Json(serde_json::json!({ "error": "wrong token" }))).into_response(),
    }
}

async fn auth_check(State(st): State<SharedState>, headers: HeaderMap) -> Json<serde_json::Value> {
    let ok = match &st.cfg.access_token {
        None => true,
        Some(expected) => token_from(&headers, None).map(|t| constant_eq(&t, expected)).unwrap_or(false),
    };
    Json(serde_json::json!({ "authenticated": ok, "required": st.cfg.access_token.is_some() }))
}

// ---- server-sent events -----------------------------------------------------------

async fn events(State(st): State<SharedState>) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = st.events.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|msg| {
        let ev = msg.ok()?;
        Some(Ok(Event::default().json_data(ev).unwrap_or_default()))
    });
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(20)))
}
