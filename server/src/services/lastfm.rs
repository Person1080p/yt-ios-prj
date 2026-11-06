//! Last.fm: web auth, now-playing, scrobbling, and similar-track discovery.

use std::collections::BTreeMap;

use anyhow::{bail, Context};
use md5::{Digest, Md5};
use serde::Serialize;
use serde_json::Value;

use crate::{
    db::Db,
    models::Track,
    services::{cache, matching},
};

const API: &str = "https://ws.audioscrobbler.com/2.0/";

#[derive(Clone)]
pub struct LastFm {
    http: reqwest::Client,
    db: Db,
    env_key: Option<String>,
    env_secret: Option<String>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct Similar {
    pub artist: String,
    pub title: String,
    pub score: f32,
}

impl LastFm {
    pub fn new(http: reqwest::Client, db: Db, key: Option<String>, secret: Option<String>) -> Self {
        Self { http, db, env_key: key, env_secret: secret }
    }

    pub async fn keys(&self) -> Option<(String, String)> {
        let key = match &self.env_key {
            Some(k) => k.clone(),
            None => self.db.get_setting("lastfm.api_key").await.ok()??,
        };
        let secret = match &self.env_secret {
            Some(s) => s.clone(),
            None => self.db.get_setting("lastfm.api_secret").await.ok()??,
        };
        Some((key, secret))
    }

    pub async fn session(&self) -> Option<(String, String)> {
        let sk = self.db.get_setting("lastfm.session_key").await.ok()??;
        let user = self.db.get_setting("lastfm.username").await.ok()?.unwrap_or_default();
        Some((sk, user))
    }

    pub async fn auth_url(&self, callback: &str) -> anyhow::Result<String> {
        let (key, _) = self.keys().await.context("Last.fm API key/secret not configured")?;
        Ok(format!(
            "https://www.last.fm/api/auth/?api_key={}&cb={}",
            urlencoding::encode(&key),
            urlencoding::encode(callback)
        ))
    }

    pub async fn complete_auth(&self, token: &str) -> anyhow::Result<String> {
        let v = self.call("auth.getSession", vec![("token", token.to_string())], true, false).await?;
        let sk = v["session"]["key"].as_str().context("no session key")?;
        let name = v["session"]["name"].as_str().unwrap_or_default();
        self.db.set_setting("lastfm.session_key", sk).await?;
        self.db.set_setting("lastfm.username", name).await?;
        Ok(name.to_string())
    }

    pub async fn disconnect(&self) -> anyhow::Result<()> {
        self.db.delete_settings("lastfm.session_key").await?;
        self.db.delete_settings("lastfm.username").await
    }

    /// Generic API call. `signed` adds api_sig; `with_session` adds sk and POSTs.
    async fn call(
        &self,
        method: &str,
        params: Vec<(&str, String)>,
        signed: bool,
        with_session: bool,
    ) -> anyhow::Result<Value> {
        let (key, secret) = self.keys().await.context("Last.fm API key/secret not configured")?;
        let mut p: BTreeMap<String, String> = params.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        p.insert("method".into(), method.into());
        p.insert("api_key".into(), key);
        if with_session {
            let (sk, _) = self.session().await.context("Last.fm not connected")?;
            p.insert("sk".into(), sk);
        }
        if signed {
            let mut base = String::new();
            for (k, v) in &p {
                base.push_str(k);
                base.push_str(v);
            }
            base.push_str(&secret);
            p.insert("api_sig".into(), hex::encode(Md5::digest(base.as_bytes())));
        }
        p.insert("format".into(), "json".into());

        let req = if signed { self.http.post(API).form(&p) } else { self.http.get(API).query(&p) };
        let v: Value = req
            .header("user-agent", "ytp/0.1")
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await?
            .json()
            .await?;
        if let Some(code) = v["error"].as_i64() {
            bail!("last.fm {method} error {code}: {}", v["message"].as_str().unwrap_or_default());
        }
        Ok(v)
    }

    fn track_params(t: &Track) -> Vec<(&'static str, String)> {
        let mut p = vec![("artist", first_artist(&t.artist)), ("track", t.title.clone())];
        if let Some(a) = &t.album {
            p.push(("album", a.clone()));
        }
        if let Some(d) = t.duration {
            p.push(("duration", d.to_string()));
        }
        p
    }

    pub async fn now_playing(&self, t: &Track) -> anyhow::Result<()> {
        self.call("track.updateNowPlaying", Self::track_params(t), true, true).await.map(|_| ())
    }

    pub async fn scrobble(&self, t: &Track, started_at: i64) -> anyhow::Result<()> {
        let mut p = Self::track_params(t);
        p.push(("timestamp", started_at.to_string()));
        let v = self.call("track.scrobble", p, true, true).await?;
        if v["scrobbles"]["@attr"]["ignored"].as_i64().unwrap_or(0) > 0 {
            let reason = &v["scrobbles"]["scrobble"]["ignoredMessage"]["#text"];
            tracing::warn!("last.fm ignored scrobble of {} - {}: {}", t.artist, t.title, reason);
        }
        Ok(())
    }

    pub async fn unlove(&self, t: &Track) -> anyhow::Result<()> {
        self.unlove_by_name(&first_artist(&t.artist), &t.title).await
    }

    pub async fn unlove_by_name(&self, artist: &str, title: &str) -> anyhow::Result<()> {
        self.call("track.unlove", vec![("artist", artist.to_string()), ("track", title.to_string())], true, true)
            .await
            .map(|_| ())
    }

    pub async fn love_by_name(&self, artist: &str, title: &str) -> anyhow::Result<()> {
        self.call("track.love", vec![("artist", artist.to_string()), ("track", title.to_string())], true, true)
            .await
            .map(|_| ())
    }

    /// Whether the connected user has loved this track (None if not connected / unknown track).
    pub async fn is_loved(&self, t: &Track) -> anyhow::Result<Option<bool>> {
        let Some((_, user)) = self.session().await else { return Ok(None) };
        let v = match self
            .call(
                "track.getInfo",
                vec![("artist", first_artist(&t.artist)), ("track", matching::normalize(&t.title)), ("username", user), ("autocorrect", "1".into())],
                false,
                false,
            )
            .await
        {
            Ok(v) => v,
            Err(_) => return Ok(None), // unknown to Last.fm
        };
        Ok(v["track"]["userloved"].as_str().map(|s| s == "1"))
    }

    /// All of the connected user's loved tracks: (artist, title).
    pub async fn loved_tracks(&self) -> anyhow::Result<Vec<(String, String)>> {
        let (_, user) = self.session().await.context("Last.fm not connected")?;
        let mut out = Vec::new();
        let mut page = 1;
        loop {
            let v = self
                .call(
                    "user.getLovedTracks",
                    vec![("user", user.clone()), ("limit", "1000".into()), ("page", page.to_string())],
                    false,
                    false,
                )
                .await?;
            let tracks = v["lovedtracks"]["track"].as_array().cloned().unwrap_or_default();
            for t in &tracks {
                if let (Some(a), Some(n)) = (t["artist"]["name"].as_str(), t["name"].as_str()) {
                    out.push((a.to_string(), n.to_string()));
                }
            }
            let total: u32 = v["lovedtracks"]["@attr"]["totalPages"].as_str().and_then(|s| s.parse().ok()).unwrap_or(1);
            if tracks.is_empty() || page >= total {
                break;
            }
            page += 1;
        }
        Ok(out)
    }

    pub async fn love(&self, t: &Track) -> anyhow::Result<()> {
        self.love_by_name(&first_artist(&t.artist), &t.title).await
    }

    pub async fn similar_tracks(&self, artist: &str, title: &str, limit: u32) -> anyhow::Result<Vec<Similar>> {
        let key = format!("lastfm:similar:{limit}:{}|{}", matching::primary_artist(artist), matching::normalize(title));
        cache::cached(&self.db, &key, 7 * cache::DAY, false, || self.fetch_similar(artist, title, limit)).await
    }

    async fn fetch_similar(&self, artist: &str, title: &str, limit: u32) -> anyhow::Result<Vec<Similar>> {
        let v = self
            .call(
                "track.getSimilar",
                vec![
                    ("artist", first_artist(artist)),
                    ("track", matching::normalize(title)),
                    ("autocorrect", "1".into()),
                    ("limit", limit.to_string()),
                ],
                false,
                false,
            )
            .await?;
        Ok(v["similartracks"]["track"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|t| {
                        Some(Similar {
                            artist: t["artist"]["name"].as_str()?.to_string(),
                            title: t["name"].as_str()?.to_string(),
                            score: t["match"].as_f64().unwrap_or(0.0) as f32,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// The connected user's top tracks over the last month (seeds for discovery).
    pub async fn top_tracks(&self, limit: u32) -> anyhow::Result<Vec<Similar>> {
        let Some((_, user)) = self.session().await else { return Ok(vec![]) };
        let key = format!("lastfm:top:{user}:{limit}");
        cache::cached(&self.db, &key, 6 * cache::HOUR, false, || self.fetch_top(user.clone(), limit)).await
    }

    async fn fetch_top(&self, user: String, limit: u32) -> anyhow::Result<Vec<Similar>> {
        let v = self
            .call(
                "user.getTopTracks",
                vec![("user", user), ("period", "1month".into()), ("limit", limit.to_string())],
                false,
                false,
            )
            .await?;
        Ok(v["toptracks"]["track"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|t| {
                        Some(Similar {
                            artist: t["artist"]["name"].as_str()?.to_string(),
                            title: t["name"].as_str()?.to_string(),
                            score: 1.0,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default())
    }
}

pub fn first_artist(s: &str) -> String {
    s.split(", ").next().unwrap_or(s).trim().to_string()
}
