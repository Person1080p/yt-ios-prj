use std::collections::HashSet;

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{
    error::{ApiResult, AppError},
    models::{ArtistPage, GridPage, SearchResults, Shelf, Track},
    services::recommend,
    state::SharedState,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeResponse {
    pub shelves: Vec<Shelf>,
}

#[derive(Deserialize)]
pub struct RefreshQuery {
    #[serde(default)]
    refresh: Option<String>,
}

pub async fn home(State(st): State<SharedState>, Query(q): Query<RefreshQuery>) -> ApiResult<HomeResponse> {
    let shelves = st.yt.home(q.refresh.is_some()).await?;
    let tracks: Vec<Track> = shelves.iter().flat_map(|s| s.items.iter().filter_map(|i| i.track.clone())).collect();
    st.db.upsert_tracks(tracks).await?;
    Ok(Json(HomeResponse { shelves }))
}

pub async fn discover(State(st): State<SharedState>) -> ApiResult<HomeResponse> {
    Ok(Json(HomeResponse { shelves: recommend::discover(&st).await? }))
}

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
    #[serde(default)]
    limit: Option<usize>,
}

pub async fn search(State(st): State<SharedState>, Query(q): Query<SearchQuery>) -> ApiResult<Vec<Track>> {
    if q.q.trim().is_empty() {
        return Ok(Json(vec![]));
    }
    let tracks = st.yt.search_songs(&q.q, q.limit.unwrap_or(30)).await?;
    st.db.upsert_tracks(tracks.clone()).await?;
    Ok(Json(tracks))
}

pub async fn radio(State(st): State<SharedState>, Path(video_id): Path<String>) -> ApiResult<Vec<Track>> {
    let tracks = st.yt.watch_playlist(Some(&video_id), None, 50).await?;
    st.db.upsert_tracks(tracks.clone()).await?;
    Ok(Json(tracks))
}

pub async fn playlist(State(st): State<SharedState>, Path(id): Path<String>) -> ApiResult<Vec<Track>> {
    let tracks = st.yt.playlist_tracks(&id, 500).await?;
    st.db.upsert_tracks(tracks.clone()).await?;
    Ok(Json(tracks))
}

#[derive(Deserialize)]
pub struct RecQuery {
    #[serde(default)]
    limit: Option<usize>,
}

/// Blended YouTube radio + Last.fm recommendations seeded by a track.
pub async fn recommendations(
    State(st): State<SharedState>,
    Path(video_id): Path<String>,
    Query(q): Query<RecQuery>,
) -> ApiResult<Vec<Track>> {
    let seed = track_or_fetch(&st, &video_id).await?;
    let exclude: HashSet<String> = st.db.recent_video_ids(30).await?.into_iter().collect();
    Ok(Json(recommend::for_track(&st, &seed, q.limit.unwrap_or(25), &exclude).await?))
}

pub async fn track(State(st): State<SharedState>, Path(video_id): Path<String>) -> ApiResult<Track> {
    Ok(Json(track_or_fetch(&st, &video_id).await?))
}

pub async fn track_or_fetch(st: &SharedState, video_id: &str) -> Result<Track, AppError> {
    if let Some(t) = st.db.get_track(video_id).await? {
        return Ok(t);
    }
    let t = st.yt.song_info(video_id).await?;
    st.db.upsert_tracks(vec![t.clone()]).await?;
    Ok(t)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    played_at: i64,
    source: String,
    scrobbled: bool,
    track: Track,
}

pub async fn history(State(st): State<SharedState>) -> ApiResult<Vec<HistoryEntry>> {
    let profile = st.db.active_profile().await;
    let rows = st
        .db
        .call(move |c| {
            let mut stmt = c.prepare(
                "SELECT h.played_at, h.source, h.scrobbled, t.video_id, t.title, t.artist, t.album, t.duration, t.thumbnail
                 FROM history h JOIN tracks t ON t.video_id = h.video_id
                 WHERE h.profile = ?1
                 ORDER BY h.played_at DESC LIMIT 200",
            )?;
            let rows = stmt.query_map([profile], |r| {
                Ok(HistoryEntry {
                    played_at: r.get(0)?,
                    source: r.get(1)?,
                    scrobbled: r.get::<_, i64>(2)? == 1,
                    track: Track {
                        video_id: r.get(3)?,
                        title: r.get(4)?,
                        artist: r.get(5)?,
                        album: r.get(6)?,
                        duration: r.get(7)?,
                        thumbnail: r.get(8)?,
                    },
                })
            })?;
            rows.collect()
        })
        .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
pub struct SearchAllQuery {
    q: String,
    /// artists | albums | songs (default: everything)
    #[serde(default)]
    filter: Option<String>,
}

/// Search across songs, artists, albums, videos and playlists (or one kind with `filter`).
pub async fn search_all(State(st): State<SharedState>, Query(q): Query<SearchAllQuery>) -> ApiResult<SearchResults> {
    if q.q.trim().is_empty() {
        return Ok(Json(SearchResults::default()));
    }
    let res = match q.filter.as_deref() {
        Some("songs") => SearchResults { songs: st.yt.search_songs(&q.q, 30).await?, ..Default::default() },
        f => st.yt.search_all(&q.q, f).await?,
    };
    let mut tracks = res.songs.clone();
    tracks.extend(res.top.iter().filter_map(|t| t.track.clone()));
    st.db.upsert_tracks(tracks).await?;
    Ok(Json(res))
}

fn valid_browse_id(id: &str) -> Result<(), AppError> {
    if id.is_empty() || id.len() > 64 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err(AppError::bad("invalid id"));
    }
    Ok(())
}

pub async fn artist(State(st): State<SharedState>, Path(id): Path<String>) -> ApiResult<ArtistPage> {
    valid_browse_id(&id)?;
    let page = st.yt.artist(&id).await?;
    st.db.upsert_tracks(page.top_songs.clone()).await?;
    Ok(Json(page))
}

#[derive(Deserialize)]
pub struct ArtistLookup {
    name: String,
}

/// The artist page id for a name: `{ "id": "UC…" }` or `{ "id": null }`.
pub async fn artist_lookup(State(st): State<SharedState>, Query(q): Query<ArtistLookup>) -> ApiResult<serde_json::Value> {
    let name = q.name.trim();
    if name.is_empty() {
        return Err(AppError::bad("name required"));
    }
    Ok(Json(serde_json::json!({ "id": st.yt.artist_id_for(name).await? })))
}

#[derive(Deserialize)]
pub struct GridQuery {
    id: String,
    #[serde(default)]
    params: Option<String>,
}

/// A grid page, e.g. an artist's full discography (the "See all" of Albums / Singles).
pub async fn browse_grid(State(st): State<SharedState>, Query(q): Query<GridQuery>) -> ApiResult<GridPage> {
    valid_browse_id(&q.id)?;
    Ok(Json(st.yt.browse_grid(&q.id, q.params.as_deref()).await?))
}
