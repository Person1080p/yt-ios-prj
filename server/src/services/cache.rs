//! Server-side response cache (SQLite) for YouTube Music / Last.fm calls.
//!
//! Fresh entries are served without touching the network. When an entry is stale we refetch,
//! but if that fails (rate limit, outage) the stale copy is returned instead of an error.

use std::future::Future;

use serde::{de::DeserializeOwned, Serialize};

use crate::db::Db;

pub const MINUTE: i64 = 60;
pub const HOUR: i64 = 60 * MINUTE;
pub const DAY: i64 = 24 * HOUR;

pub async fn cached<T, F, Fut>(db: &Db, key: &str, ttl: i64, refresh: bool, fetch: F) -> anyhow::Result<T>
where
    T: Serialize + DeserializeOwned,
    F: FnOnce() -> Fut,
    Fut: Future<Output = anyhow::Result<T>>,
{
    let mut stale = None;
    if let Ok(Some((json, fresh))) = db.cache_get(key).await {
        if fresh && !refresh {
            if let Ok(v) = serde_json::from_str(&json) {
                return Ok(v);
            }
        } else {
            stale = Some(json);
        }
    }
    match fetch().await {
        Ok(v) => {
            if let Ok(json) = serde_json::to_string(&v) {
                let _ = db.cache_put(key, &json, ttl).await;
            }
            Ok(v)
        }
        Err(e) => match stale.and_then(|j| serde_json::from_str(&j).ok()) {
            Some(v) => {
                tracing::warn!("serving cached {key} after fetch error: {e:#}");
                Ok(v)
            }
            None => Err(e),
        },
    }
}

/// Hourly cleanup of long-expired entries.
pub fn spawn_purge_loop(db: Db) {
    tokio::spawn(async move {
        let mut t = tokio::time::interval(std::time::Duration::from_secs(HOUR as u64));
        loop {
            t.tick().await;
            if let Ok(n) = db.cache_purge().await {
                if n > 0 {
                    tracing::debug!("purged {n} expired cache entries");
                }
            }
        }
    });
}
