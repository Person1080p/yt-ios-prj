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

/// Songs that are only in Plex (no YouTube match) use `plex_<ratingKey>` where other songs use
/// their YouTube video id. Such ids never reach YouTube: playback is Plex only.
pub const ID_PREFIX: &str = "plex_";

/// The rating key in a Plex-only id.
pub fn rating_key(video_id: &str) -> Option<&str> {
    video_id.strip_prefix(ID_PREFIX).filter(|k| !k.is_empty() && k.len() <= 15 && k.bytes().all(|b| b.is_ascii_digit()))
}

pub fn is_plex_id(video_id: &str) -> bool {
    rating_key(video_id).is_some()
}

/// A track found on the Plex server, with what matching and display need.
#[derive(Debug, Clone)]
pub struct PlexHit {
    pub track: PlexTrack,
    pub duration: Option<u32>,
    pub album_artist: String,
    pub album: Option<String>,
    /// Plex artwork path (served through `/api/plex/art`).
    pub thumb: Option<String>,
}

impl PlexHit {
    /// From a track's Plex metadata JSON.
    fn parse(m: &Value) -> Option<Self> {
        let media = &m["Media"][0];
        let part_key = media["Part"][0]["key"].as_str()?;
        let album_artist = m["grandparentTitle"].as_str().unwrap_or_default().to_string();
        Some(Self {
            track: PlexTrack {
                rating_key: m["ratingKey"].as_str().unwrap_or_default().into(),
                part_key: part_key.into(),
                codec: media["audioCodec"].as_str().map(String::from),
                title: m["title"].as_str().unwrap_or_default().into(),
                artist: m["originalTitle"].as_str().map(String::from).unwrap_or_else(|| album_artist.clone()),
            },
            duration: m["duration"].as_u64().map(|ms| (ms / 1000) as u32),
            album_artist,
            album: m["parentTitle"].as_str().filter(|s| !s.is_empty()).map(String::from),
            thumb: m["thumb"].as_str().or_else(|| m["parentThumb"].as_str()).map(String::from),
        })
    }

    /// As a song in the app, under its Plex-only id.
    pub fn to_track(&self) -> Track {
        Track {
            video_id: format!("{ID_PREFIX}{}", self.track.rating_key),
            title: self.track.title.clone(),
            artist: self.track.artist.clone(),
            album: self.album.clone(),
            duration: self.duration,
            thumbnail: self.thumb.as_deref().map(|p| format!("/api/plex/art?path={}", urlencoding::encode(p))),
        }
    }
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

    pub async fn search(&self, query: &str) -> anyhow::Result<Vec<PlexHit>> {
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
            out.extend(hub["Metadata"].as_array().into_iter().flatten().filter_map(PlexHit::parse));
        }
        Ok(out)
    }

    /// A track by its rating key (None when the server no longer has it).
    pub async fn track_by_key(&self, rating_key: &str) -> anyhow::Result<Option<PlexHit>> {
        let Some((url, token)) = self.server().await else { bail!("plex not configured") };
        let resp = self
            .http
            .get(format!("{url}/library/metadata/{}", urlencoding::encode(rating_key)))
            .header("accept", "application/json")
            .header("X-Plex-Token", token)
            .timeout(std::time::Duration::from_secs(8))
            .send()
            .await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let v: Value = resp.error_for_status()?.json().await?;
        Ok(v["MediaContainer"]["Metadata"].as_array().and_then(|a| a.first()).and_then(PlexHit::parse))
    }

    /// The Plex track behind a Plex-only id (`plex_<ratingKey>`), cached like matches.
    pub async fn track_for_id(&self, video_id: &str) -> anyhow::Result<Option<PlexTrack>> {
        let Some(rk) = rating_key(video_id) else { return Ok(None) };
        if let Some((true, Some(t), _)) = self.cached(video_id).await? {
            return Ok(Some(t));
        }
        let found = self.track_by_key(rk).await?.map(|h| h.track);
        if found.is_some() {
            self.store(video_id, found.as_ref()).await?;
        }
        Ok(found)
    }

    /// Play `video_id` (a YouTube track) from this Plex track, whatever automatic matching thinks.
    pub async fn pin(&self, video_id: &str, rating_key: &str) -> anyhow::Result<PlexTrack> {
        let Some(hit) = self.track_by_key(rating_key).await? else { bail!("that track is no longer on the Plex server") };
        self.store(video_id, Some(&hit.track)).await?;
        Ok(hit.track)
    }

    /// Artwork from the Plex server, resized. `path` is a Plex thumb path from [`PlexHit`].
    pub async fn art(&self, path: &str) -> anyhow::Result<Vec<u8>> {
        if !path.starts_with("/library/metadata/") || path.contains("..") {
            bail!("not a plex artwork path");
        }
        let Some((url, token)) = self.server().await else { bail!("plex not configured") };
        let bytes = self
            .http
            .get(format!("{url}/photo/:/transcode"))
            .query(&[("width", "400"), ("height", "400"), ("minSize", "1"), ("upscale", "1"), ("url", path)])
            .header("X-Plex-Token", token)
            .timeout(std::time::Duration::from_secs(15))
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await?;
        Ok(bytes.to_vec())
    }

    /// (matched, track, checked_at) from the match cache.
    async fn cached(&self, video_id: &str) -> anyhow::Result<Option<(bool, Option<PlexTrack>, i64)>> {
        let vid = video_id.to_string();
        let row = self
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
        Ok(row.map(|(matched, rk, pk, codec, title, artist, checked)| {
            let track = matched.then(|| PlexTrack {
                rating_key: rk.unwrap_or_default(),
                part_key: pk.unwrap_or_default(),
                codec,
                title: title.unwrap_or_default(),
                artist: artist.unwrap_or_default(),
            });
            (matched, track, checked)
        }))
    }

    /// Find the Plex copy of a YouTube track, with a persistent cache.
    pub async fn find_match(&self, track: &Track) -> anyhow::Result<Option<PlexTrack>> {
        if is_plex_id(&track.video_id) {
            return self.track_for_id(&track.video_id).await;
        }
        if let Some((matched, t, checked)) = self.cached(&track.video_id).await? {
            if matched {
                return Ok(t);
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
            .map(|h| {
                let pt = h.track;
                let s1 = matching::score(&track.title, &track.artist, track.duration, &pt.title, &pt.artist, h.duration);
                let s2 = matching::score(&track.title, &track.artist, track.duration, &pt.title, &h.album_artist, h.duration);
                (s1.max(s2), pt)
            })
            .max_by(|a, b| a.0.total_cmp(&b.0));

        let result = best.filter(|(s, _)| *s >= MATCH_THRESHOLD).map(|(_, t)| t);
        self.store(&track.video_id, result.as_ref()).await?;
        Ok(result)
    }

    /// Save a match (or that there is none) for `video_id`.
    async fn store(&self, video_id: &str, track: Option<&PlexTrack>) -> anyhow::Result<()> {
        let vid = video_id.to_string();
        let r = track.cloned();
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
            .await
    }

    /// URL to fetch audio for a matched track. Browser-friendly codecs are served
    /// directly; others go through Plex's universal transcoder as MP3.
    ///
    /// `budget_kbps` (from the browser's measured connection to this server): when the original
    /// file is bigger than that, Plex transcodes it to an MP3 that fits. Returns the URL and the
    /// (approximate) bitrate that will be sent.
    pub async fn stream_url(&self, t: &PlexTrack, budget_kbps: Option<u32>) -> anyhow::Result<(String, u32)> {
        let Some((url, token)) = self.server().await else { bail!("plex not configured") };
        let codec = t.codec.as_deref().map(str::to_ascii_lowercase);
        let direct = matches!(codec.as_deref(), None | Some("mp3" | "aac" | "flac" | "opus" | "vorbis" | "pcm" | "wav"));
        // The match cache doesn't keep the file's bitrate: assume typical values per codec.
        let original = if matches!(codec.as_deref(), Some("flac" | "alac" | "pcm" | "wav")) { 1000 } else { 320 };
        if direct && budget_kbps.map_or(true, |b| b >= original) {
            return Ok((format!("{url}{}?X-Plex-Token={}", t.part_key, urlencoding::encode(&token)), original));
        }
        let rate = plex_bitrate(budget_kbps);
        let cid = self.client_id().await?;
        let path = urlencoding::encode(&format!("/library/metadata/{}", t.rating_key)).into_owned();
        Ok((
            format!(
                "{url}/music/:/transcode/universal/start.mp3?path={path}&mediaIndex=0&partIndex=0&protocol=http\
                 &directPlay=0&directStream=0&musicBitrate={rate}&X-Plex-Product={PRODUCT}&X-Plex-Platform=Chrome\
                 &X-Plex-Client-Identifier={cid}&X-Plex-Token={}",
                urlencoding::encode(&token)
            ),
            rate,
        ))
    }
}

/// MP3 bitrate for a Plex transcode within `budget_kbps` (320 when unlimited, never below 64).
pub fn plex_bitrate(budget_kbps: Option<u32>) -> u32 {
    let budget = budget_kbps.unwrap_or(320);
    [320, 256, 192, 128, 96, 64].into_iter().find(|&r| r <= budget).unwrap_or(64)
}

#[cfg(test)]
mod id_tests {
    use super::*;

    #[test]
    fn plex_ids() {
        assert_eq!(rating_key("plex_12345"), Some("12345"));
        assert!(is_plex_id("plex_1"));
        assert!(!is_plex_id("plex_"));
        assert!(!is_plex_id("plex_12a"));
        assert!(!is_plex_id("dQw4w9WgXcQ"));
    }

    #[test]
    fn parses_metadata() {
        let m = serde_json::json!({
            "ratingKey": "42", "title": "Song", "grandparentTitle": "Band", "parentTitle": "Album",
            "duration": 201500, "thumb": "/library/metadata/40/thumb/1700000000",
            "Media": [{ "audioCodec": "flac", "Part": [{ "key": "/library/parts/9/file.flac" }] }]
        });
        let h = PlexHit::parse(&m).unwrap();
        assert_eq!(h.track.artist, "Band");
        let t = h.to_track();
        assert_eq!(t.video_id, "plex_42");
        assert_eq!(t.duration, Some(201));
        assert_eq!(t.album.as_deref(), Some("Album"));
        assert_eq!(t.thumbnail.as_deref(), Some("/api/plex/art?path=%2Flibrary%2Fmetadata%2F40%2Fthumb%2F1700000000"));
    }
}

#[cfg(test)]
mod quality_tests {
    #[test]
    fn plex_bitrate_fits_budget() {
        assert_eq!(super::plex_bitrate(None), 320);
        assert_eq!(super::plex_bitrate(Some(200)), 192);
        assert_eq!(super::plex_bitrate(Some(96)), 96);
        assert_eq!(super::plex_bitrate(Some(10)), 64);
    }
}
