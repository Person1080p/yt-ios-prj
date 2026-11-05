//! Switching between your normal profile and the "fresh start" one.

use axum::{extract::State, Json};
use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::{
    error::{ApiResult, AppError},
    models::now,
    services::{
        profile::{self, FRESH, FRESH_STARTED_KEY, FRESH_VISITOR_KEY, MAIN, PROFILE_KEY},
        queue::Queue,
    },
    state::{ServerEvent, SharedState},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileInfo {
    /// "main" | "fresh"
    active: String,
    fresh_plays: i64,
    fresh_started_at: Option<i64>,
}

async fn info(st: &SharedState) -> anyhow::Result<ProfileInfo> {
    let plays = st
        .db
        .call(|c| c.query_row("SELECT COUNT(*) FROM history WHERE profile=?1", [FRESH], |r| r.get(0)))
        .await?;
    Ok(ProfileInfo {
        active: st.db.active_profile().await,
        fresh_plays: plays,
        fresh_started_at: st.db.get_setting(FRESH_STARTED_KEY).await?.and_then(|s| s.parse().ok()),
    })
}

pub async fn get(State(st): State<SharedState>) -> ApiResult<ProfileInfo> {
    Ok(Json(info(&st).await?))
}

#[derive(Deserialize)]
pub struct SetBody {
    active: String,
}

/// Switch profile: the current queue is saved and the other profile's queue is loaded.
pub async fn set(State(st): State<SharedState>, Json(b): Json<SetBody>) -> ApiResult<ProfileInfo> {
    let target = match b.active.as_str() {
        MAIN | FRESH => b.active.clone(),
        _ => return Err(AppError::bad("profile must be \"main\" or \"fresh\"")),
    };
    let snapshot = {
        let mut q = st.queue.lock().await;
        if q.profile != target {
            q.save(&st.db).await?;
            st.db.set_setting(PROFILE_KEY, &target).await?;
            if target == FRESH && st.db.get_setting(FRESH_STARTED_KEY).await?.is_none() {
                st.db.set_setting(FRESH_STARTED_KEY, &now().to_string()).await?;
            }
            let mut next = Queue::load_profile(&st.db, &target).await;
            // Keep versions increasing across switches so clients never ignore the new queue.
            next.version = next.version.max(q.version) + 1;
            *q = next;
        }
        q.clone()
    };
    tracing::info!("listener profile: {target}");
    st.emit(ServerEvent::Profile { active: target });
    st.emit(ServerEvent::Queue { queue: snapshot });
    Ok(Json(info(&st).await?))
}

/// Make the fresh profile brand new again: forget its plays, queue and YouTube visitor identity.
pub async fn reset_fresh(State(st): State<SharedState>) -> ApiResult<ProfileInfo> {
    st.db
        .call(|c| c.execute("DELETE FROM history WHERE profile=?1", params![FRESH]).map(|_| ()))
        .await?;
    st.db.delete_settings(&profile::queue_key(FRESH)).await?;
    st.db.delete_settings(FRESH_VISITOR_KEY).await?;
    st.db.set_setting(FRESH_STARTED_KEY, &now().to_string()).await?;
    let snapshot = {
        let mut q = st.queue.lock().await;
        if q.profile == FRESH {
            let version = q.version + 1;
            *q = Queue::load_profile(&st.db, FRESH).await;
            q.version = version;
            Some(q.clone())
        } else {
            None
        }
    };
    if let Some(queue) = snapshot {
        st.emit(ServerEvent::Queue { queue });
    }
    st.emit(ServerEvent::Profile { active: st.db.active_profile().await });
    Ok(Json(info(&st).await?))
}
