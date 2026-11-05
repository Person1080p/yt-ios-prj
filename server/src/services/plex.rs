//! Plex / Plexamp integration: PIN login, server selection, track matching and stream URLs.

use anyhow::{bail, Context};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use serde_json::Value;

use crate::{
    db::Db,
    models::{now, Track},
    services::matching,
};

const PRODUCT: &str = "ytp";
const NEGATIVE_TTL: i64 = 60 * 60 * 24 * 3;
const MATCH_THRESHOLD: f32 = 0.82;

#[derive(Clone)]
pub struct Plex {
    http: reqwest::Client,
    db: Db,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexTrack {
    pub rating_key: String,
    pub part_key: String,
    pub codec: Option<String>,
    pub title: String,
    pub artist: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexPin {
    pub id: i64,
    pub code: String,
    pub auth_url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexServer {
    pub name: String,
    pub client_identifier: String,
    pub access_token: String,
    pub owned: bool,
    pub connections: Vec<PlexConnection>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexConnection {
    pub uri: String,
    pub local: bool,
    pub relay: bool,
}

impl Plex {
    pub fn new(http: reqwest::Client, db: Db) -> Self {
        Self { http, db }
    }

    async fn client_id(&self) -> anyhow::Result<String> {
        if let Some(id) = self.db.get_setting("plex.client_id").await? {
            return Ok(id);
        }
        let id = uuid::Uuid::new_v4().to_string();
        self.db.set_setting("plex.client_id", &id).await?;
        Ok(id)
    }

    /// (server url, server token)
    pub async fn server(&self) -> Option<(String, String)> {
        let url = self.db.get_setting("plex.url").await.ok()??;
        let token = self.db.get_setting("plex.token").await.ok()??;
        Some((url, token))
    }

    pub async fn enabled(&self) -> bool {
        self.server().await.is_some() && self.db.get_bool("prefs.prefer_plex", true).await
    }

    async fn plex_tv(&self, method: reqwest::Method, path: &str, token: Option<&str>) -> anyhow::Result<Value> {
        let cid = self.client_id().await?;
        let mut req = self
            .http
            .request(method, format!("https://plex.tv{path}"))
            .header("accept", "application/json")
            .header("X-Plex-Product", PRODUCT)
            .header("X-Plex-Client-Identifier", cid);
        if let Some(t) = token {
            req = req.header("X-Plex-Token", t);
        }
        Ok(req.send().await?.error_for_status()?.json().await?)
    }

    // ---- login ------------------------------------------------------------

    pub async fn start_pin(&self) -> anyhow::Result<PlexPin> {
        let v = self.plex_tv(reqwest::Method::POST, "/api/v2/pins?strong=true", None).await?;
        let id = v["id"].as_i64().context("pin id")?;
        let code = v["code"].as_str().context("pin code")?.to_string();
        let cid = self.client_id().await?;
        let auth_url = format!(
            "https://app.plex.tv/auth#?clientID={}&code={}&context%5Bdevice%5D%5Bproduct%5D={}",
            urlencoding::encode(&cid),
            urlencoding::encode(&code),
            PRODUCT
        );
        Ok(PlexPin { id, code, auth_url })
    }

    /// Returns true once the user has approved the PIN; the account token is stored.
    pub async fn check_pin(&self, id: i64) -> anyhow::Result<bool> {
        let v = self.plex_tv(reqwest::Method::GET, &format!("/api/v2/pins/{id}"), None).await?;
        match v["authToken"].as_str() {
            Some(t) if !t.is_empty() => {
                self.db.set_setting("plex.account_token", t).await?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    pub async fn servers(&self) -> anyhow::Result<Vec<PlexServer>> {
        let token = self.db.get_setting("plex.account_token").await?.context("not logged in to plex.tv")?;
        let v = self
            .plex_tv(reqwest::Method::GET, "/api/v2/resources?includeHttps=1&includeRelay=1", Some(&token))
            .await?;
        let servers = v
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter(|r| r["provides"].as_str().unwrap_or_default().contains("server"))
                    .map(|r| PlexServer {
                        name: r["name"].as_str().unwrap_or_default().into(),
                        client_identifier: r["clientIdentifier"].as_str().unwrap_or_default().into(),
                        access_token: r["accessToken"].as_str().unwrap_or(&token).into(),
                        owned: r["owned"].as_bool().unwrap_or(false),
                        connections: r["connections"]
                            .as_array()
                            .map(|cs| {
                                cs.iter()
                                    .map(|c| PlexConnection {
                                        uri: c["uri"].as_str().unwrap_or_default().into(),
                                        local: c["local"].as_bool().unwrap_or(false),
                                        relay: c["relay"].as_bool().unwrap_or(false),
                                    })
                                    .collect()
                            })
                            .unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(servers)
    }

    /// Save a server connection after verifying it answers.
    pub async fn set_server(&self, url: &str, token: &str) -> anyhow::Result<String> {
        let url = url.trim_end_matches('/').to_string();
        let v: Value = self
            .http
            .get(format!("{url}/identity"))
            .header("accept", "application/json")
            .header("X-Plex-Token", token)
            .timeout(std::time::Duration::from_secs(8))
            .send()
            .await
            .context("could not reach plex server")?
            .error_for_status()?
            .json()
            .await?;
        let name = v["MediaContainer"]["machineIdentifier"].as_str().unwrap_or("plex").to_string();
        self.db.set_setting("plex.url", &url).await?;
        self.db.set_setting("plex.token", token).await?;
        self.clear_cache().await?;
        Ok(name)
    }

    pub async fn disconnect(&self) -> anyhow::Result<()> {
        for k in ["plex.url", "plex.token", "plex.account_token"] {
            self.db.call({
                let k = k.to_string();
                move |c| c.execute("DELETE FROM settings WHERE key=?1", [k])
            })
            .await?;
        }
        self.clear_cache().await
    }

    async fn clear_cache(&self) -> anyhow::Result<()> {
        self.db.call(|c| c.execute("DELETE FROM plex_matches", []).map(|_| ())).await
    }

    // ---- matching ---------------------------------------------------------

    pub async fn search(&self, query: &str) -> anyhow::Result<Vec<(PlexTrack, Option<u32>, String)>> {
        let Some((url, token)) = self.server().await else { bail!("plex not configured") };
        let v: Value = self
            .http
            .get(format!("{url}/hubs/search"))
            .query(&[("query", query), ("limit", "15"), ("includeCollections", "0")])
            .header("accept", "application/json")
            .header("X-Plex-Token", token)
            .timeout(std::time::Duration::from_secs(8))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let mut out = Vec::new();
        for hub in v["MediaContainer"]["Hub"].as_array().into_iter().flatten() {
            if hub["type"].as_str() != Some("track") {
                continue;
            }
            for m in hub["Metadata"].as_array().into_iter().flatten() {
                let media = &m["Media"][0];
                let Some(part_key) = media["Part"][0]["key"].as_str() else { continue };
                let artist = m["originalTitle"]
                    .as_str()
                    .or_else(|| m["grandparentTitle"].as_str())
                    .unwrap_or_default()
                    .to_string();
                out.push((
                    PlexTrack {
                        rating_key: m["ratingKey"].as_str().unwrap_or_default().into(),
                        part_key: part_key.into(),
                        codec: media["audioCodec"].as_str().map(String::from),
                        title: m["title"].as_str().unwrap_or_default().into(),
                        artist,
                    },
                    m["duration"].as_u64().map(|ms| (ms / 1000) as u32),
                    m["grandparentTitle"].as_str().unwrap_or_default().to_string(),
                ));
            }
        }
        Ok(out)
    }

    /// Find the Plex copy of a YouTube track, with a persistent cache.
    pub async fn find_match(&self, track: &Track) -> anyhow::Result<Option<PlexTrack>> {
        let vid = track.video_id.clone();
        let cached = self
            .db
            .call(move |c| {
                c.query_row(
                    "SELECT matched, rating_key, part_key, codec, title, artist, checked_at FROM plex_matches WHERE video_id=?1",
                    [vid],
                    |r| {
                        Ok((
                            r.get::<_, bool>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, Option<String>>(2)?,
                            r.get::<_, Option<String>>(3)?,
                            r.get::<_, Option<String>>(4)?,
                            r.get::<_, Option<String>>(5)?,
                            r.get::<_, i64>(6)?,
                        ))
                    },
                )
                .optional()
            })
            .await?;
        if let Some((matched, rk, pk, codec, title, artist, checked)) = cached {
            if matched {
                return Ok(Some(PlexTrack {
                    rating_key: rk.unwrap_or_default(),
                    part_key: pk.unwrap_or_default(),
                    codec,
                    title: title.unwrap_or_default(),
                    artist: artist.unwrap_or_default(),
                }));
            }
            if now() - checked < NEGATIVE_TTL {
                return Ok(None);
            }
        }

        let title_q = matching::normalize(&track.title);
        let mut candidates = self.search(&title_q).await?;
        if candidates.is_empty() {
            candidates = self.search(&format!("{} {}", matching::primary_artist(&track.artist), title_q)).await?;
        }
        let best = candidates
            .into_iter()
            .map(|(pt, dur, album_artist)| {
                let s1 = matching::score(&track.title, &track.artist, track.duration, &pt.title, &pt.artist, dur);
                let s2 = matching::score(&track.title, &track.artist, track.duration, &pt.title, &album_artist, dur);
                (s1.max(s2), pt)
            })
            .max_by(|a, b| a.0.total_cmp(&b.0));

        let result = best.filter(|(s, _)| *s >= MATCH_THRESHOLD).map(|(_, t)| t);
        let vid = track.video_id.clone();
        let r = result.clone();
        self.db
            .call(move |c| {
                c.execute(
                    "INSERT OR REPLACE INTO plex_matches(video_id,matched,rating_key,part_key,codec,title,artist,checked_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
                    params![
                        vid,
                        r.is_some(),
                        r.as_ref().map(|t| &t.rating_key),
                        r.as_ref().map(|t| &t.part_key),
                        r.as_ref().and_then(|t| t.codec.clone()),
                        r.as_ref().map(|t| &t.title),
                        r.as_ref().map(|t| &t.artist),
                        now()
                    ],
                )
                .map(|_| ())
            })
            .await?;
        Ok(result)
    }

    /// URL to fetch audio for a matched track. Browser-friendly codecs are served
    /// directly; others go through Plex's universal transcoder as MP3.
    pub async fn stream_url(&self, t: &PlexTrack) -> anyhow::Result<String> {
        let Some((url, token)) = self.server().await else { bail!("plex not configured") };
        let direct = matches!(
            t.codec.as_deref().map(str::to_ascii_lowercase).as_deref(),
            None | Some("mp3" | "aac" | "flac" | "opus" | "vorbis" | "pcm" | "wav")
        );
        if direct {
            return Ok(format!("{url}{}?X-Plex-Token={}", t.part_key, urlencoding::encode(&token)));
        }
        let cid = self.client_id().await?;
        let path = urlencoding::encode(&format!("/library/metadata/{}", t.rating_key)).into_owned();
        Ok(format!(
            "{url}/music/:/transcode/universal/start.mp3?path={path}&mediaIndex=0&partIndex=0&protocol=http\
             &directPlay=0&directStream=0&musicBitrate=320&X-Plex-Product={PRODUCT}&X-Plex-Platform=Chrome\
             &X-Plex-Client-Identifier={cid}&X-Plex-Token={}",
            urlencoding::encode(&token)
        ))
    }
}
