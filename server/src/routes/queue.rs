use std::collections::HashSet;

use axum::{extract::State, Json};
use serde::Deserialize;

use crate::{
    error::{ApiResult, AppError},
    models::Track,
    services::{
        queue::{InsertAt, Queue},
        recommend,
    },
    state::{ServerEvent, SharedState},
};

const AUTOFILL_WHEN_REMAINING: usize = 3;

/// Apply a mutation, persist, broadcast, and top up with recommendations when running low.
async fn mutate<F>(st: &SharedState, f: F) -> ApiResult<Queue>
where
    F: FnOnce(&mut Queue) -> Result<(), AppError>,
{
    let snapshot = {
        let mut q = st.queue.lock().await;
        f(&mut q)?;
        q.save(&st.db).await?;
        q.clone()
    };
    st.emit(ServerEvent::Queue { queue: snapshot.clone() });
    maybe_autofill(st.clone(), &snapshot);
    Ok(Json(snapshot))
}

fn maybe_autofill(st: SharedState, q: &Queue) {
    if !q.autoplay || q.items.is_empty() || q.remaining() >= AUTOFILL_WHEN_REMAINING {
        return;
    }
    let Some(seed) = q.items.last().map(|i| i.track.clone()) else { return };
    let mut exclude: HashSet<String> = q.items.iter().map(|i| i.track.video_id.clone()).collect();
    crate::services::ytlog::spawn("queue autofill", async move {
        if let Ok(recent) = st.db.recent_video_ids(30).await {
            exclude.extend(recent);
        }
        let recs = match recommend::for_track(&st, &seed, 15, &exclude).await {
            Ok(r) if !r.is_empty() => r,
            Ok(_) => return,
            Err(e) => {
                tracing::warn!("autofill failed: {e:#}");
                return;
            }
        };
        let snapshot = {
            let mut q = st.queue.lock().await;
            // Queue may have changed meanwhile; only fill if still needed.
            if !q.autoplay || q.remaining() >= AUTOFILL_WHEN_REMAINING {
                return;
            }
            q.append_auto(recs);
            if q.save(&st.db).await.is_err() {
                return;
            }
            q.clone()
        };
        st.emit(ServerEvent::Queue { queue: snapshot });
    });
}

pub async fn get(State(st): State<SharedState>) -> ApiResult<Queue> {
    Ok(Json(st.queue.lock().await.clone()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddBody {
    tracks: Vec<Track>,
    #[serde(default)]
    at: InsertAt,
}

pub async fn add(State(st): State<SharedState>, Json(b): Json<AddBody>) -> ApiResult<Queue> {
    st.db.upsert_tracks(b.tracks.clone()).await?;
    mutate(&st, |q| {
        q.add(b.tracks, b.at);
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplaceBody {
    tracks: Vec<Track>,
    #[serde(default)]
    index: usize,
}

pub async fn replace(State(st): State<SharedState>, Json(b): Json<ReplaceBody>) -> ApiResult<Queue> {
    st.db.upsert_tracks(b.tracks.clone()).await?;
    mutate(&st, |q| {
        q.replace(b.tracks, b.index);
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct RadioBody {
    track: Track,
}

/// Start a radio: play this track now, followed by blended recommendations.
pub async fn radio(State(st): State<SharedState>, Json(b): Json<RadioBody>) -> ApiResult<Queue> {
    st.db.upsert_tracks(vec![b.track.clone()]).await?;
    let exclude: HashSet<String> = st.db.recent_video_ids(20).await?.into_iter().collect();
    let mut tracks = vec![b.track.clone()];
    tracks.extend(recommend::for_track(&st, &b.track, 30, &exclude).await?);
    mutate(&st, |q| {
        q.replace(tracks, 0);
        q.autoplay = true;
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct IndexBody {
    index: usize,
}

pub async fn set_index(State(st): State<SharedState>, Json(b): Json<IndexBody>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        if b.index >= q.items.len() {
            return Err(AppError::bad("index out of range"));
        }
        q.index = b.index;
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct MoveBody {
    from: usize,
    to: usize,
}

pub async fn move_item(State(st): State<SharedState>, Json(b): Json<MoveBody>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        q.move_item(b.from, b.to);
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct RemoveBody {
    uid: String,
}

pub async fn remove(State(st): State<SharedState>, Json(b): Json<RemoveBody>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        q.remove(&b.uid);
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct ClearBody {
    #[serde(default)]
    all: bool,
}

pub async fn clear(State(st): State<SharedState>, Json(b): Json<ClearBody>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        if b.all {
            q.clear()
        } else {
            q.clear_upcoming()
        }
        Ok(())
    })
    .await
}

pub async fn shuffle(State(st): State<SharedState>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        q.shuffle_upcoming();
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct AutoplayBody {
    enabled: bool,
}

pub async fn autoplay(State(st): State<SharedState>, Json(b): Json<AutoplayBody>) -> ApiResult<Queue> {
    mutate(&st, |q| {
        q.autoplay = b.enabled;
        if !b.enabled {
            // Drop pending auto-generated tracks after the current one.
            let keep = q.index + 1;
            let mut i = 0;
            q.items.retain(|it| {
                let k = i < keep || !it.auto;
                i += 1;
                k
            });
        }
        Ok(())
    })
    .await
}
