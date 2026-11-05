//! Locally saved playlists ("saved queues").

use axum::{
    extract::{Path, State},
    Json,
};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::{
    db::row_to_track,
    error::{ApiResult, AppError},
    models::{now, Track},
    state::SharedState,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistSummary {
    id: i64,
    name: String,
    count: i64,
    updated_at: i64,
    thumbnail: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Playlist {
    id: i64,
    name: String,
    tracks: Vec<Track>,
}

pub async fn list(State(st): State<SharedState>) -> ApiResult<Vec<PlaylistSummary>> {
    let rows = st
        .db
        .call(|c| {
            let mut stmt = c.prepare(
                "SELECT p.id, p.name, p.updated_at,
                        (SELECT COUNT(*) FROM playlist_items i WHERE i.playlist_id=p.id),
                        (SELECT t.thumbnail FROM playlist_items i JOIN tracks t ON t.video_id=i.video_id
                          WHERE i.playlist_id=p.id ORDER BY i.pos LIMIT 1)
                 FROM playlists p ORDER BY p.updated_at DESC",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(PlaylistSummary { id: r.get(0)?, name: r.get(1)?, updated_at: r.get(2)?, count: r.get(3)?, thumbnail: r.get(4)? })
            })?;
            rows.collect()
        })
        .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
pub struct CreateBody {
    name: String,
    #[serde(default)]
    tracks: Vec<Track>,
}

pub async fn create(State(st): State<SharedState>, Json(b): Json<CreateBody>) -> ApiResult<Playlist> {
    let name = b.name.trim().to_string();
    if name.is_empty() {
        return Err(AppError::bad("name required"));
    }
    st.db.upsert_tracks(b.tracks.clone()).await?;
    let ids: Vec<String> = b.tracks.iter().map(|t| t.video_id.clone()).collect();
    let n = name.clone();
    let id = st
        .db
        .call(move |c| {
            let tx = c.transaction()?;
            tx.execute("INSERT INTO playlists(name, created_at, updated_at) VALUES(?1,?2,?2)", params![n, now()])?;
            let id = tx.last_insert_rowid();
            for (i, v) in ids.iter().enumerate() {
                tx.execute("INSERT INTO playlist_items(playlist_id,pos,video_id) VALUES(?1,?2,?3)", params![id, i as i64, v])?;
            }
            tx.commit()?;
            Ok(id)
        })
        .await?;
    Ok(Json(Playlist { id, name, tracks: b.tracks }))
}

pub async fn get(State(st): State<SharedState>, Path(id): Path<i64>) -> ApiResult<Playlist> {
    let res = st
        .db
        .call(move |c| {
            let Some(name) = c.query_row("SELECT name FROM playlists WHERE id=?1", [id], |r| r.get::<_, String>(0)).optional()? else {
                return Ok(None);
            };
            let mut stmt = c.prepare(
                "SELECT t.video_id,t.title,t.artist,t.album,t.duration,t.thumbnail
                 FROM playlist_items i JOIN tracks t ON t.video_id=i.video_id
                 WHERE i.playlist_id=?1 ORDER BY i.pos",
            )?;
            let tracks = stmt.query_map([id], row_to_track)?.collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(Some(Playlist { id, name, tracks }))
        })
        .await?;
    res.map(Json).ok_or(AppError::NotFound)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateBody {
    #[serde(default)]
    name: Option<String>,
    /// Full replacement of the track list (ordering/removal).
    #[serde(default)]
    tracks: Option<Vec<Track>>,
    /// Tracks appended to the end.
    #[serde(default)]
    append: Option<Vec<Track>>,
}

pub async fn update(State(st): State<SharedState>, Path(id): Path<i64>, Json(b): Json<UpdateBody>) -> ApiResult<Playlist> {
    let mut all = b.tracks.clone().unwrap_or_default();
    all.extend(b.append.clone().unwrap_or_default());
    st.db.upsert_tracks(all).await?;
    st.db
        .call(move |c| {
            let tx = c.transaction()?;
            if let Some(n) = b.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                tx.execute("UPDATE playlists SET name=?1 WHERE id=?2", params![n, id])?;
            }
            if let Some(tracks) = &b.tracks {
                tx.execute("DELETE FROM playlist_items WHERE playlist_id=?1", [id])?;
                for (i, t) in tracks.iter().enumerate() {
                    tx.execute("INSERT INTO playlist_items(playlist_id,pos,video_id) VALUES(?1,?2,?3)", params![id, i as i64, t.video_id])?;
                }
            }
            if let Some(append) = &b.append {
                let start: i64 = tx.query_row("SELECT COALESCE(MAX(pos)+1,0) FROM playlist_items WHERE playlist_id=?1", [id], |r| r.get(0))?;
                for (i, t) in append.iter().enumerate() {
                    tx.execute("INSERT INTO playlist_items(playlist_id,pos,video_id) VALUES(?1,?2,?3)", params![id, start + i as i64, t.video_id])?;
                }
            }
            tx.execute("UPDATE playlists SET updated_at=?1 WHERE id=?2", params![now(), id])?;
            tx.commit()
        })
        .await?;
    get(State(st), Path(id)).await
}

pub async fn delete(State(st): State<SharedState>, Path(id): Path<i64>) -> ApiResult<serde_json::Value> {
    st.db.call(move |c| c.execute("DELETE FROM playlists WHERE id=?1", [id])).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
