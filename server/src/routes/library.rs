//! Liked-track library and imports.

use axum::{
    extract::{Query, State},
    Json,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::{
    error::{ApiResult, AppError},
    models::Track,
    services::{fileimport, importers},
    state::SharedState,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LikedEntry {
    id: i64,
    provider: String,
    title: String,
    artist: String,
    album: Option<String>,
    status: String,
    track: Option<Track>,
}

#[derive(Deserialize)]
pub struct LikedQuery {
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    q: Option<String>,
}

pub async fn liked(State(st): State<SharedState>, Query(q): Query<LikedQuery>) -> ApiResult<Vec<LikedEntry>> {
    let rows = st
        .db
        .call(move |c| {
            let like = q.q.as_deref().map(|s| format!("%{}%", s.trim())).unwrap_or_else(|| "%".into());
            let mut stmt = c.prepare(
                "SELECT l.id, l.provider, l.title, l.artist, l.album, l.status,
                        t.video_id, t.title, t.artist, t.album, t.duration, t.thumbnail
                 FROM liked l LEFT JOIN tracks t ON t.video_id = l.video_id
                 WHERE (?1 IS NULL OR l.provider = ?1)
                   AND (?2 IS NULL OR l.status = ?2)
                   AND (l.title LIKE ?3 OR l.artist LIKE ?3)
                 ORDER BY l.added_at DESC, l.id DESC
                 LIMIT 5000",
            )?;
            let rows = stmt.query_map(params![q.provider, q.status, like], |r| {
                let vid: Option<String> = r.get(6)?;
                let track = match vid {
                    Some(video_id) => Some(Track {
                        video_id,
                        title: r.get(7)?,
                        artist: r.get(8)?,
                        album: r.get(9)?,
                        duration: r.get(10)?,
                        thumbnail: r.get(11)?,
                    }),
                    None => None,
                };
                Ok(LikedEntry {
                    id: r.get(0)?,
                    provider: r.get(1)?,
                    title: r.get(2)?,
                    artist: r.get(3)?,
                    album: r.get(4)?,
                    status: r.get(5)?,
                    track,
                })
            })?;
            rows.collect()
        })
        .await?;
    Ok(Json(rows))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    id: i64,
    provider: String,
    status: String,
    total: i64,
    done: i64,
    matched: i64,
    error: Option<String>,
    started_at: i64,
    finished_at: Option<i64>,
}

pub async fn jobs(State(st): State<SharedState>) -> ApiResult<Vec<Job>> {
    let rows = st
        .db
        .call(|c| {
            let mut stmt = c.prepare(
                "SELECT id,provider,status,total,done,matched,error,started_at,finished_at FROM import_jobs ORDER BY id DESC LIMIT 20",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(Job {
                    id: r.get(0)?,
                    provider: r.get(1)?,
                    status: r.get(2)?,
                    total: r.get(3)?,
                    done: r.get(4)?,
                    matched: r.get(5)?,
                    error: r.get(6)?,
                    started_at: r.get(7)?,
                    finished_at: r.get(8)?,
                })
            })?;
            rows.collect()
        })
        .await?;
    Ok(Json(rows))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobStarted {
    job_id: i64,
}

pub async fn import_ytmusic(State(st): State<SharedState>) -> ApiResult<JobStarted> {
    if !st.yt.is_authenticated().await {
        return Err(AppError::NotConfigured("Add your YouTube Music cookie in Settings first".into()));
    }
    let job_id = importers::start(st.clone(), "ytmusic", importers::ytmusic_liked(st.clone())).await?;
    Ok(Json(JobStarted { job_id }))
}

pub async fn import_spotify(State(st): State<SharedState>) -> ApiResult<JobStarted> {
    if st.db.get_setting("spotify.refresh_token").await?.is_none() {
        return Err(AppError::NotConfigured("Connect Spotify first".into()));
    }
    let job_id = importers::start(st.clone(), "spotify", importers::spotify_liked(st.clone())).await?;
    Ok(Json(JobStarted { job_id }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeezerBody {
    user_id: String,
    #[serde(default)]
    access_token: Option<String>,
}

pub async fn import_deezer(State(st): State<SharedState>, Json(b): Json<DeezerBody>) -> ApiResult<JobStarted> {
    let user_id = b.user_id.trim().trim_start_matches("https://www.deezer.com/").to_string();
    // Accept a profile URL like https://www.deezer.com/en/profile/12345
    let user_id = user_id.rsplit('/').next().unwrap_or(&user_id).to_string();
    if user_id.is_empty() {
        return Err(AppError::bad("Deezer user id required"));
    }
    st.db.set_setting("deezer.user_id", &user_id).await?;
    let token = b.access_token.filter(|t| !t.trim().is_empty());
    let job_id = importers::start(st.clone(), "deezer", importers::deezer_favorites(st.http.clone(), user_id, token)).await?;
    Ok(Json(JobStarted { job_id }))
}

#[derive(Deserialize)]
pub struct TextBody {
    content: String,
    #[serde(default)]
    provider: Option<String>,
}

pub async fn import_text(State(st): State<SharedState>, Json(b): Json<TextBody>) -> ApiResult<JobStarted> {
    let items = importers::parse_text(&b.content)?;
    if items.is_empty() {
        return Err(AppError::bad("No tracks found. Use a CSV export or 'Artist - Title' lines."));
    }
    let provider = b.provider.filter(|p| !p.is_empty()).unwrap_or_else(|| "file".into());
    let job_id = importers::start(st.clone(), &provider, async move { Ok(items) }).await?;
    Ok(Json(JobStarted { job_id }))
}

// ---- arbitrary export files (Demus, JSON, plist, zip, M3U, CSV, ...) ---------------------

#[derive(Deserialize)]
pub struct FileQuery {
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

pub async fn import_file(
    State(st): State<SharedState>,
    Query(q): Query<FileQuery>,
    body: axum::body::Bytes,
) -> ApiResult<JobStarted> {
    let name = q.name.unwrap_or_else(|| "upload".into());
    let items = fileimport::parse(&body, &name).map_err(|e| AppError::bad(format!("{e:#}")))?;
    let provider = q.provider.filter(|p| !p.is_empty()).unwrap_or_else(|| "file".into());
    let job_id = importers::start(st.clone(), &provider, async move { Ok(items) }).await?;
    Ok(Json(JobStarted { job_id }))
}

// ---- Spotify OAuth (PKCE) ----------------------------------------------------------------
// The redirect goes to a page route in the web app (works the same whether the app talks
// to the server directly or through the in-browser tailnet), which then posts the code here.

#[derive(Serialize)]
pub struct UrlResponse {
    url: String,
}

#[derive(Deserialize)]
pub struct LoginQuery {
    redirect: String,
}

pub async fn spotify_login(State(st): State<SharedState>, Query(q): Query<LoginQuery>) -> ApiResult<UrlResponse> {
    let client_id = st
        .cfg
        .spotify_client_id
        .clone()
        .ok_or_else(|| AppError::NotConfigured("Set SPOTIFY_CLIENT_ID on the server".into()))?;
    let (verifier, challenge) = importers::spotify_pkce();
    let state_param = uuid::Uuid::new_v4().simple().to_string();
    st.spotify_pkce.lock().await.insert(state_param.clone(), (verifier, q.redirect.clone()));
    Ok(Json(UrlResponse { url: importers::spotify_auth_url(&client_id, &q.redirect, &challenge, &state_param) }))
}

#[derive(Deserialize)]
pub struct ExchangeBody {
    code: String,
    state: String,
}

pub async fn spotify_exchange(State(st): State<SharedState>, Json(b): Json<ExchangeBody>) -> ApiResult<serde_json::Value> {
    let (verifier, redirect) = st
        .spotify_pkce
        .lock()
        .await
        .remove(&b.state)
        .ok_or_else(|| AppError::bad("Spotify login expired, try again"))?;
    importers::spotify_exchange(&st, &b.code, &verifier, &redirect).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
