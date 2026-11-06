//! Server-side response cache (SQLite) for YouTube Music / Last.fm calls.
//!
//! Fresh entries are served without touching the network. When an entry is stale we refetch,
//! but if that fails (rate limit, outage) the stale copy is returned instead of an error.

use std::{
    collections::BTreeMap,
    future::Future,
    sync::{Arc, Mutex},
};

use serde::{de::DeserializeOwned, Serialize};

use crate::db::Db;

pub const MINUTE: i64 = 60;
pub const HOUR: i64 = 60 * MINUTE;
pub const DAY: i64 = 24 * HOUR;

/// Keys being fetched right now. A second request for the same key waits for the first one
/// and then reads its result from the cache, instead of asking YouTube a second time (e.g. the
/// home page loading twice at once, or two devices opening it together).
static IN_FLIGHT: Mutex<BTreeMap<String, Arc<tokio::sync::Mutex<()>>>> = Mutex::new(BTreeMap::new());

pub struct Flight {
    key: String,
    lock: Arc<tokio::sync::Mutex<()>>,
    guard: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl Flight {
    /// Returns the flight and whether we had to wait for another request with the same key.
    /// Hold the returned value while doing the work; others with the same key wait for it.
    pub async fn join(key: &str) -> (Self, bool) {
        let lock = IN_FLIGHT.lock().unwrap_or_else(|p| p.into_inner()).entry(key.to_string()).or_default().clone();
        let (guard, waited) = match lock.clone().try_lock_owned() {
            Ok(g) => (g, false),
            Err(_) => (lock.clone().lock_owned().await, true),
        };
        (Self { key: key.to_string(), lock, guard: Some(guard) }, waited)
    }
}

impl Drop for Flight {
    fn drop(&mut self) {
        self.guard.take();
        let mut m = IN_FLIGHT.lock().unwrap_or_else(|p| p.into_inner());
        // Only the map and this handle hold it: nobody is waiting, so forget the key.
        if Arc::strong_count(&self.lock) <= 2 {
            m.remove(&self.key);
        }
    }
}

pub async fn cached<T, F, Fut>(db: &Db, key: &str, ttl: i64, refresh: bool, fetch: F) -> anyhow::Result<T>
where
    T: Serialize + DeserializeOwned,
    F: FnOnce() -> Fut,
    Fut: Future<Output = anyhow::Result<T>>,
{
    let (_flight, waited) = Flight::join(key).await;
    // If we waited on an identical request, its answer is seconds old: use it even for a refresh.
    let refresh = refresh && !waited;
    let mut stale = None;
    if let Ok(Some((json, fresh))) = db.cache_get(key).await {
        if fresh && !refresh {
            if let Ok(v) = serde_json::from_str(&json) {
                crate::services::ytlog::cache_event(key, "hit");
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
                crate::services::ytlog::cache_event(key, "stale");
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
