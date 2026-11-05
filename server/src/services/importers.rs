//! Importing liked tracks from YouTube Music, Spotify, Deezer and CSV/text exports.

use anyhow::{bail, Context};
use base64::Engine;
use rusqlite::params;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::{
    models::{now, ImportItem},
    services::resolver,
    state::{ServerEvent, SharedState},
};

// ---- job runner -------------------------------------------------------------

/// Create an import job and run it in the background. `fetch` produces the provider's items.
pub async fn start<F>(state: SharedState, provider: &str, fetch: F) -> anyhow::Result<i64>
where
    F: std::future::Future<Output = anyhow::Result<Vec<ImportItem>>> + Send + 'static,
{
    let p = provider.to_string();
    let job_id = state
        .db
        .call(move |c| {
            c.execute("INSERT INTO import_jobs(provider,status,started_at) VALUES(?1,'running',?2)", params![p, now()])?;
            Ok(c.last_insert_rowid())
        })
        .await?;

    let provider = provider.to_string();
    tokio::spawn(async move {
        let result = run(&state, job_id, &provider, fetch).await;
        let (status, err) = match result {
            Ok(()) => ("done", None),
            Err(e) => {
                tracing::error!("import {provider} failed: {e:#}");
                ("failed", Some(format!("{e:#}")))
            }
        };
        let _ = state
            .db
            .call(move |c| {
                c.execute(
                    "UPDATE import_jobs SET status=?1, error=?2, finished_at=?3 WHERE id=?4",
                    params![status, err, now(), job_id],
                )
            })
            .await;
        state.emit(ServerEvent::Import { job_id });
    });
    Ok(job_id)
}

async fn run<F>(state: &SharedState, job_id: i64, provider: &str, fetch: F) -> anyhow::Result<()>
where
    F: std::future::Future<Output = anyhow::Result<Vec<ImportItem>>>,
{
    let items = fetch.await?;
    let total = items.len() as i64;
    state.db.call(move |c| c.execute("UPDATE import_jobs SET total=?1 WHERE id=?2", params![total, job_id])).await?;
    state.emit(ServerEvent::Import { job_id });

    let mut matched = 0i64;
    for (i, it) in items.into_iter().enumerate() {
        // Skip re-matching rows that were already matched by a previous import.
        let (p, pid) = (provider.to_string(), it.provider_id.clone());
        let existing: Option<String> = state
            .db
            .call(move |c| {
                c.query_row("SELECT video_id FROM liked WHERE provider=?1 AND provider_id=?2", params![p, pid], |r| r.get(0))
                    .or_else(|e| if e == rusqlite::Error::QueryReturnedNoRows { Ok(None) } else { Err(e) })
            })
            .await?;

        // "error" = the lookup itself failed (e.g. rate limited) — retried by "Retry unmatched".
        let mut status = "unmatched";
        let video_id = match (it.video_id.clone(), existing) {
            (Some(v), _) => {
                ensure_track(state, &v, &it).await;
                Some(v)
            }
            (None, Some(v)) => Some(v),
            (None, None) => {
                let r = resolver::resolve(&state.yt, &state.db, &it.artist, &it.title, it.duration).await;
                tokio::time::sleep(std::time::Duration::from_millis(600)).await;
                match r {
                    Ok(t) => t.map(|t| t.video_id),
                    Err(e) => {
                        tracing::warn!("lookup failed for {} - {}: {e:#}", it.artist, it.title);
                        status = "error";
                        None
                    }
                }
            }
        };
        if video_id.is_some() {
            status = "matched";
        }
        if video_id.is_some() {
            matched += 1;
        }
        let p = provider.to_string();
        let done = i as i64 + 1;
        state
            .db
            .call(move |c| {
                c.execute(
                    "INSERT INTO liked(provider,provider_id,title,artist,album,duration,video_id,status,added_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                     ON CONFLICT(provider,provider_id) DO UPDATE SET
                       title=excluded.title, artist=excluded.artist, album=excluded.album,
                       duration=excluded.duration,
                       -- never overwrite a match the user picked by hand
                       video_id=CASE WHEN liked.status='manual' THEN liked.video_id ELSE excluded.video_id END,
                       status=CASE WHEN liked.status='manual' THEN 'manual' ELSE excluded.status END",
                    params![
                        p,
                        it.provider_id,
                        it.title,
                        it.artist,
                        it.album,
                        it.duration,
                        video_id,
                        status,
                        now()
                    ],
                )?;
                c.execute("UPDATE import_jobs SET done=?1, matched=?2 WHERE id=?3", params![done, matched, job_id])
            })
            .await?;
        if done % 10 == 0 {
            state.emit(ServerEvent::Import { job_id });
        }
    }
    Ok(())
}

/// Make sure a track row exists for an item that already carries a YouTube id.
/// Uses the export's own metadata when complete, otherwise asks YouTube.
async fn ensure_track(state: &SharedState, video_id: &str, it: &ImportItem) {
    if matches!(state.db.get_track(video_id).await, Ok(Some(_))) {
        return;
    }
    let track = if !it.title.is_empty() && !it.artist.is_empty() {
        Some(crate::models::Track {
            video_id: video_id.to_string(),
            title: it.title.clone(),
            artist: it.artist.clone(),
            album: it.album.clone(),
            duration: it.duration,
            thumbnail: Some(format!("https://i.ytimg.com/vi/{video_id}/hqdefault.jpg")),
        })
    } else {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        match state.yt.song_info(video_id).await {
            Ok(t) => Some(t),
            Err(e) => {
                tracing::debug!("song_info {video_id}: {e:#}");
                None
            }
        }
    };
    if let Some(t) = track {
        let _ = state.db.upsert_tracks(vec![t]).await;
    }
}

// ---- retry unmatched ---------------------------------------------------------------

/// Re-run matching for library entries that are unmatched or whose lookup failed,
/// ignoring cached "no match" results.
pub async fn start_rematch(state: SharedState) -> anyhow::Result<i64> {
    let job_id = state
        .db
        .call(|c| {
            c.execute("INSERT INTO import_jobs(provider,status,started_at) VALUES('rematch','running',?1)", params![now()])?;
            Ok(c.last_insert_rowid())
        })
        .await?;
    tokio::spawn(async move {
        let res = rematch(&state, job_id).await;
        let (status, err) = match res {
            Ok(()) => ("done", None),
            Err(e) => ("failed", Some(format!("{e:#}"))),
        };
        let _ = state
            .db
            .call(move |c| {
                c.execute("UPDATE import_jobs SET status=?1, error=?2, finished_at=?3 WHERE id=?4", params![status, err, now(), job_id])
            })
            .await;
        state.emit(ServerEvent::Import { job_id });
    });
    Ok(job_id)
}

async fn rematch(state: &SharedState, job_id: i64) -> anyhow::Result<()> {
    let rows: Vec<(i64, String, String, Option<u32>)> = state
        .db
        .call(|c| {
            let mut st = c.prepare("SELECT id, artist, title, duration FROM liked WHERE status IN ('unmatched','error')")?;
            let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
            rows.collect()
        })
        .await?;
    let total = rows.len() as i64;
    state.db.call(move |c| c.execute("UPDATE import_jobs SET total=?1 WHERE id=?2", params![total, job_id])).await?;
    let mut matched = 0i64;
    for (i, (id, artist, title, duration)) in rows.into_iter().enumerate() {
        let (vid, status) = match resolver::resolve_opts(&state.yt, &state.db, &artist, &title, duration, true).await {
            Ok(Some(t)) => (Some(t.video_id), "matched"),
            Ok(None) => (None, "unmatched"),
            Err(e) => {
                tracing::warn!("lookup failed for {artist} - {title}: {e:#}");
                (None, "error")
            }
        };
        if vid.is_some() {
            matched += 1;
        }
        let done = i as i64 + 1;
        state
            .db
            .call(move |c| {
                c.execute("UPDATE liked SET video_id=?1, status=?2 WHERE id=?3 AND status<>'manual'", params![vid, status, id])?;
                c.execute("UPDATE import_jobs SET done=?1, matched=?2 WHERE id=?3", params![done, matched, job_id])
            })
            .await?;
        if done % 10 == 0 {
            state.emit(ServerEvent::Import { job_id });
        }
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
    }
    Ok(())
}

// ---- Last.fm loved tracks ---------------------------------------------------------------

pub const LASTFM_SYNC_PREF: &str = "prefs.lastfm_sync_loves";

pub async fn lastfm_loved(state: SharedState) -> anyhow::Result<Vec<ImportItem>> {
    let loved = state.lastfm.loved_tracks().await?;
    let items: Vec<ImportItem> = loved
        .into_iter()
        .map(|(artist, title)| ImportItem {
            provider_id: format!("{}|{}", artist.to_lowercase(), title.to_lowercase()),
            title,
            artist,
            album: None,
            duration: None,
            video_id: None,
        })
        .collect();
    // Mirror un-loves: drop Last.fm entries that are no longer loved.
    let keep: std::collections::HashSet<String> = items.iter().map(|i| i.provider_id.clone()).collect();
    let existing: Vec<(i64, String)> = state
        .db
        .call(|c| {
            let mut st = c.prepare("SELECT id, provider_id FROM liked WHERE provider='lastfm'")?;
            let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect()
        })
        .await?;
    let gone: Vec<i64> = existing.into_iter().filter(|(_, pid)| !keep.contains(pid)).map(|(id, _)| id).collect();
    if !gone.is_empty() {
        let n = gone.len();
        state
            .db
            .call(move |c| {
                for id in gone {
                    c.execute("DELETE FROM liked WHERE id=?1", [id])?;
                }
                Ok(())
            })
            .await?;
        tracing::info!("removed {n} tracks no longer loved on Last.fm");
    }
    Ok(items)
}

/// Daily Last.fm loves sync, when enabled.
pub fn spawn_lastfm_sync(state: SharedState) {
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(120)).await;
        loop {
            if state.db.get_bool(LASTFM_SYNC_PREF, false).await && state.lastfm.session().await.is_some() {
                if let Err(e) = start(state.clone(), "lastfm", lastfm_loved(state.clone())).await {
                    tracing::warn!("Last.fm loves sync: {e:#}");
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(24 * 60 * 60)).await;
        }
    });
}

// ---- YouTube Music ------------------------------------------------------------

pub async fn ytmusic_liked(state: SharedState) -> anyhow::Result<Vec<ImportItem>> {
    let tracks = state.yt.liked_songs(10_000).await?;
    state.db.upsert_tracks(tracks.clone()).await?;
    Ok(tracks
        .into_iter()
        .map(|t| ImportItem {
            provider_id: t.video_id.clone(),
            title: t.title,
            artist: t.artist,
            album: t.album,
            duration: t.duration,
            video_id: Some(t.video_id),
        })
        .collect())
}

// ---- Spotify (Authorization Code + PKCE, no client secret needed) -------------

pub fn spotify_pkce() -> (String, String) {
    use rand::Rng;
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    let verifier: String = (0..64).map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char).collect();
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

pub fn spotify_auth_url(client_id: &str, redirect: &str, challenge: &str, state: &str) -> String {
    format!(
        "https://accounts.spotify.com/authorize?response_type=code&client_id={}&redirect_uri={}&code_challenge_method=S256&code_challenge={}&state={}&scope={}",
        urlencoding::encode(client_id),
        urlencoding::encode(redirect),
        challenge,
        state,
        urlencoding::encode("user-library-read playlist-read-private")
    )
}

async fn spotify_store_tokens(state: &SharedState, v: &Value) -> anyhow::Result<String> {
    let access = v["access_token"].as_str().context("no access_token")?.to_string();
    state.db.set_setting("spotify.access_token", &access).await?;
    if let Some(r) = v["refresh_token"].as_str() {
        state.db.set_setting("spotify.refresh_token", r).await?;
    }
    let exp = now() + v["expires_in"].as_i64().unwrap_or(3600) - 60;
    state.db.set_setting("spotify.expires_at", &exp.to_string()).await?;
    Ok(access)
}

pub async fn spotify_exchange(state: &SharedState, code: &str, verifier: &str, redirect: &str) -> anyhow::Result<()> {
    let client_id = state.cfg.spotify_client_id.clone().context("SPOTIFY_CLIENT_ID not set")?;
    let v: Value = state
        .http
        .post("https://accounts.spotify.com/api/token")
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect),
            ("client_id", &client_id),
            ("code_verifier", verifier),
        ])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    spotify_store_tokens(state, &v).await.map(|_| ())
}

async fn spotify_token(state: &SharedState) -> anyhow::Result<String> {
    let exp: i64 = state.db.get_setting("spotify.expires_at").await?.and_then(|s| s.parse().ok()).unwrap_or(0);
    if exp > now() {
        if let Some(t) = state.db.get_setting("spotify.access_token").await? {
            return Ok(t);
        }
    }
    let refresh = state.db.get_setting("spotify.refresh_token").await?.context("Spotify not connected")?;
    let client_id = state.cfg.spotify_client_id.clone().context("SPOTIFY_CLIENT_ID not set")?;
    let v: Value = state
        .http
        .post("https://accounts.spotify.com/api/token")
        .form(&[("grant_type", "refresh_token"), ("refresh_token", &refresh), ("client_id", &client_id)])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    spotify_store_tokens(state, &v).await
}

pub async fn spotify_liked(state: SharedState) -> anyhow::Result<Vec<ImportItem>> {
    let mut out = Vec::new();
    let mut url = Some("https://api.spotify.com/v1/me/tracks?limit=50".to_string());
    while let Some(u) = url.take() {
        let token = spotify_token(&state).await?;
        let resp = state.http.get(&u).bearer_auth(token).send().await?;
        if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let wait = resp.headers().get("retry-after").and_then(|h| h.to_str().ok()?.parse().ok()).unwrap_or(5);
            tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
            url = Some(u);
            continue;
        }
        let v: Value = resp.error_for_status()?.json().await?;
        for it in v["items"].as_array().into_iter().flatten() {
            let t = &it["track"];
            let Some(id) = t["id"].as_str() else { continue };
            out.push(ImportItem {
                provider_id: id.to_string(),
                title: t["name"].as_str().unwrap_or_default().to_string(),
                artist: t["artists"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|x| x["name"].as_str()).collect::<Vec<_>>().join(", "))
                    .unwrap_or_default(),
                album: t["album"]["name"].as_str().map(String::from),
                duration: t["duration_ms"].as_u64().map(|ms| (ms / 1000) as u32),
                video_id: None,
            });
        }
        url = v["next"].as_str().map(String::from);
    }
    Ok(out)
}

// ---- Deezer -----------------------------------------------------------------

/// Deezer favourites. Works without auth when the user's profile is public;
/// an access token (from an existing Deezer app) can be supplied for private profiles.
pub async fn deezer_favorites(http: reqwest::Client, user_id: String, token: Option<String>) -> anyhow::Result<Vec<ImportItem>> {
    let mut out = Vec::new();
    let mut url = Some(format!("https://api.deezer.com/user/{}/tracks?limit=100", urlencoding::encode(&user_id)));
    while let Some(u) = url.take() {
        let mut req = http.get(&u);
        if let Some(t) = &token {
            req = req.query(&[("access_token", t)]);
        }
        let v: Value = req.send().await?.error_for_status()?.json().await?;
        if let Some(err) = v.get("error") {
            bail!("deezer: {}", err["message"].as_str().unwrap_or("unknown error"));
        }
        for t in v["data"].as_array().into_iter().flatten() {
            out.push(ImportItem {
                provider_id: t["id"].as_i64().map(|i| i.to_string()).unwrap_or_default(),
                title: t["title"].as_str().unwrap_or_default().to_string(),
                artist: t["artist"]["name"].as_str().unwrap_or_default().to_string(),
                album: t["album"]["title"].as_str().map(String::from),
                duration: t["duration"].as_u64().map(|d| d as u32),
                video_id: None,
            });
        }
        url = v["next"].as_str().map(String::from);
    }
    Ok(out)
}

// ---- CSV / plain text ---------------------------------------------------------

/// Accepts CSV exports (Exportify, TuneMyMusic, Soundiiz, Deezer exports, ...) or
/// plain "Artist - Title" lines.
pub fn parse_text(content: &str) -> anyhow::Result<Vec<ImportItem>> {
    let first = content.lines().next().unwrap_or_default().to_lowercase();
    let looks_csv = first.contains(',') && (first.contains("title") || first.contains("track") || first.contains("name"));
    if !looks_csv {
        return Ok(content
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .filter_map(|l| {
                let (artist, title) = l.split_once(" - ").or_else(|| l.split_once(" – "))?;
                Some(ImportItem {
                    provider_id: format!("{}|{}", artist.trim().to_lowercase(), title.trim().to_lowercase()),
                    title: title.trim().into(),
                    artist: artist.trim().into(),
                    album: None,
                    duration: None,
                    video_id: None,
                })
            })
            .collect());
    }

    let mut rdr = csv::ReaderBuilder::new().flexible(true).from_reader(content.as_bytes());
    let headers: Vec<String> = rdr.headers()?.iter().map(|h| h.trim().to_lowercase()).collect();
    let find = |names: &[&str]| headers.iter().position(|h| names.iter().any(|n| h == n));
    let title_i = find(&["track name", "title", "track", "name", "song", "track title"]).context("no title column in CSV")?;
    let artist_i = find(&["artist name(s)", "artist name", "artist", "artists", "artist(s)"]).context("no artist column in CSV")?;
    let album_i = find(&["album name", "album", "album title"]);
    let dur_ms_i = find(&["duration (ms)", "duration_ms", "track duration (ms)"]);
    let dur_s_i = find(&["duration", "length"]);
    let id_i = find(&["track uri", "spotify - id", "isrc", "id", "track id"]);

    let mut out = Vec::new();
    for rec in rdr.records() {
        let rec = rec?;
        let get = |i: Option<usize>| i.and_then(|i| rec.get(i)).map(str::trim).filter(|s| !s.is_empty());
        let (Some(title), Some(artist)) = (get(Some(title_i)), get(Some(artist_i))) else { continue };
        let duration = get(dur_ms_i)
            .and_then(|d| d.parse::<u64>().ok())
            .map(|ms| (ms / 1000) as u32)
            .or_else(|| get(dur_s_i).and_then(|d| crate::models::parse_duration(d).or_else(|| d.parse().ok())));
        out.push(ImportItem {
            provider_id: get(id_i)
                .map(String::from)
                .unwrap_or_else(|| format!("{}|{}", artist.to_lowercase(), title.to_lowercase())),
            title: title.into(),
            artist: artist.replace(';', ", "),
            album: get(album_i).map(String::from),
            duration,
            video_id: None,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_exportify_csv() {
        let csv = "Track URI,Track Name,Artist Name(s),Album Name,Duration (ms)\nspotify:track:1,Get Lucky,\"Daft Punk;Pharrell Williams\",RAM,248000\n";
        let items = parse_text(csv).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].artist, "Daft Punk, Pharrell Williams");
        assert_eq!(items[0].duration, Some(248));
    }

    #[test]
    fn parses_lines() {
        let items = parse_text("Daft Punk - Get Lucky\n\nEminem - Lose Yourself").unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].title, "Lose Yourself");
    }
}
