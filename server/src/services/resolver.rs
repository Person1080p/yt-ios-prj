//! Map (artist, title) pairs from other services onto YouTube Music video ids.

use rusqlite::{params, OptionalExtension};

use crate::{
    db::Db,
    models::{now, Track},
    services::{matching, ytmusic::YtMusic},
};

const THRESHOLD: f32 = 0.62;
const NEGATIVE_TTL: i64 = 60 * 60 * 24 * 7;

pub async fn resolve(
    yt: &YtMusic,
    db: &Db,
    artist: &str,
    title: &str,
    duration: Option<u32>,
) -> anyhow::Result<Option<Track>> {
    let key = format!("{}|{}", matching::primary_artist(artist), matching::normalize(title));
    let k = key.clone();
    let cached: Option<(Option<String>, i64)> = db
        .call(move |c| {
            c.query_row("SELECT video_id, created_at FROM lookup_cache WHERE key=?1", [k], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()
        })
        .await?;
    match cached {
        Some((Some(vid), _)) => {
            if let Some(t) = db.get_track(&vid).await? {
                return Ok(Some(t));
            }
        }
        Some((None, at)) if now() - at < NEGATIVE_TTL => return Ok(None),
        _ => {}
    }

    let results = yt.search_songs(&format!("{artist} {title}"), 8).await?;
    let best = results
        .into_iter()
        .map(|t| (matching::score(title, artist, duration, &t.title, &t.artist, t.duration), t))
        .max_by(|a, b| a.0.total_cmp(&b.0))
        .filter(|(s, _)| *s >= THRESHOLD)
        .map(|(_, t)| t);

    if let Some(t) = &best {
        db.upsert_tracks(vec![t.clone()]).await?;
    }
    let vid = best.as_ref().map(|t| t.video_id.clone());
    db.call(move |c| {
        c.execute(
            "INSERT OR REPLACE INTO lookup_cache(key, video_id, created_at) VALUES(?1,?2,?3)",
            params![key, vid, now()],
        )
        .map(|_| ())
    })
    .await?;
    Ok(best)
}
