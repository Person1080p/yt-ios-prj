//! Import liked tracks / playlists from library export files whose format we
//! don't control — primarily Demus (an iOS YouTube-based player whose export is
//! an undocumented data file), but also anything else people throw at it.
//!
//! The file is sniffed and unpacked (zip, gzip, binary/XML plist incl.
//! NSKeyedArchiver, SQLite/Core Data, JSON, M3U, CSV/text), turned into a JSON
//! tree, and then walked for "track-shaped" objects: something with a title and
//! an artist and/or a YouTube video id. YouTube ids are used directly, so
//! Demus libraries (which are YouTube-backed) import without fuzzy matching.

use std::{
    collections::HashSet,
    io::{Cursor, Read},
    sync::LazyLock,
};

use anyhow::{bail, Context};
use regex::Regex;
use serde_json::{Map, Value};

use crate::{models::ImportItem, services::importers};

const MAX_DEPTH: usize = 64;
const MAX_UNPACKED: u64 = 256 * 1024 * 1024;

static YT_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|embed/|shorts/|v/)|youtu\.be/|music\.youtube\.com/watch\?(?:.*&)?v=)([A-Za-z0-9_-]{11})").unwrap()
});
static YT_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_-]{11}$").unwrap());

/// Parse an uploaded export into import items.
pub fn parse(bytes: &[u8], filename: &str) -> anyhow::Result<Vec<ImportItem>> {
    let mut items = Vec::new();
    collect(bytes, filename, 0, &mut items)?;
    dedupe(&mut items);
    if items.is_empty() {
        bail!(
            "No tracks found in {filename}. Supported: Demus exports, JSON, plist, SQLite, zip, M3U, CSV, or 'Artist - Title' lines."
        );
    }
    Ok(items)
}

fn collect(bytes: &[u8], name: &str, depth: usize, out: &mut Vec<ImportItem>) -> anyhow::Result<()> {
    if depth > 4 {
        return Ok(());
    }
    let lower = name.to_ascii_lowercase();

    // ---- containers --------------------------------------------------------------
    if bytes.starts_with(b"PK\x03\x04") {
        let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).context("reading zip")?;
        for i in 0..zip.len() {
            let mut f = zip.by_index(i)?;
            let entry_name = f.name().map(|n| n.to_string()).unwrap_or_default();
            if f.is_dir() || entry_name.starts_with("__MACOSX") {
                continue;
            }
            let mut buf = Vec::new();
            (&mut f).take(MAX_UNPACKED).read_to_end(&mut buf)?;
            if let Err(e) = collect(&buf, &entry_name, depth + 1, out) {
                tracing::debug!("skipping {entry_name} in zip: {e:#}");
            }
        }
        return Ok(());
    }
    if bytes.starts_with(&[0x1f, 0x8b]) {
        let mut buf = Vec::new();
        flate2::read::GzDecoder::new(bytes).take(MAX_UNPACKED).read_to_end(&mut buf)?;
        return collect(&buf, lower.trim_end_matches(".gz"), depth + 1, out);
    }

    // ---- structured data ------------------------------------------------------------
    if bytes.starts_with(b"SQLite format 3\0") {
        let v = sqlite_to_json(bytes)?;
        walk(&v, 0, out);
        return Ok(());
    }
    if bytes.starts_with(b"bplist") || lower.ends_with(".plist") || looks_like_xml_plist(bytes) {
        let pv = plist::Value::from_reader(Cursor::new(bytes)).context("reading plist")?;
        let v = plist_to_json(&pv);
        walk(&unarchive(v), 0, out);
        return Ok(());
    }

    let text = String::from_utf8_lossy(bytes);
    let trimmed = text.trim_start_matches('\u{feff}').trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
            walk(&v, 0, out);
            return Ok(());
        }
        // JSON lines
        let mut any = false;
        for line in trimmed.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                walk(&v, 0, out);
                any = true;
            }
        }
        if any {
            return Ok(());
        }
    }
    if trimmed.starts_with("#EXTM3U") || lower.ends_with(".m3u") || lower.ends_with(".m3u8") {
        out.extend(parse_m3u(trimmed));
        return Ok(());
    }

    // ---- plain text: CSV, "Artist - Title", or bare YouTube links ----------------------
    let links: Vec<ImportItem> = trimmed
        .lines()
        .filter_map(|l| {
            let id = YT_URL.captures(l)?.get(1)?.as_str().to_string();
            Some(ImportItem { provider_id: id.clone(), title: String::new(), artist: String::new(), album: None, duration: None, video_id: Some(id) })
        })
        .collect();
    if !links.is_empty() && links.len() * 2 >= trimmed.lines().filter(|l| !l.trim().is_empty()).count() {
        out.extend(links);
        return Ok(());
    }
    if !trimmed.is_empty() {
        out.extend(importers::parse_text(trimmed)?);
    }
    Ok(())
}

fn looks_like_xml_plist(b: &[u8]) -> bool {
    let head = String::from_utf8_lossy(&b[..b.len().min(512)]);
    head.contains("<plist") || head.contains("PropertyList-1.0.dtd")
}

// ---- generic track extraction ---------------------------------------------------------

fn get_ci<'a>(m: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    for k in keys {
        for (mk, v) in m {
            if mk.eq_ignore_ascii_case(k) && !v.is_null() {
                return Some(v);
            }
        }
    }
    None
}

/// Strings, numbers, `{name|title|text}` objects, or arrays thereof.
fn as_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.trim().to_string()).filter(|s| !s.is_empty()),
        Value::Array(a) => {
            let parts: Vec<String> = a.iter().filter_map(as_text).collect();
            (!parts.is_empty()).then(|| parts.join(", "))
        }
        Value::Object(m) => get_ci(m, &["name", "title", "text", "displayName"]).and_then(as_text),
        _ => None,
    }
}

fn find_video_id(m: &Map<String, Value>) -> Option<String> {
    for k in ["videoId", "youtubeId", "youtubeVideoId", "ytId", "ytVideoId", "video_id", "youtube_id", "sourceId", "externalId"] {
        if let Some(Value::String(s)) = get_ci(m, &[k]) {
            if YT_ID.is_match(s) {
                return Some(s.clone());
            }
            if let Some(c) = YT_URL.captures(s) {
                return Some(c[1].to_string());
            }
        }
    }
    // Any string field holding a YouTube URL.
    for v in m.values() {
        if let Value::String(s) = v {
            if let Some(c) = YT_URL.captures(s) {
                return Some(c[1].to_string());
            }
        }
    }
    // A bare `id` that looks like a YouTube id, if the object is otherwise YouTube-ish.
    if let Some(Value::String(s)) = get_ci(m, &["id", "identifier"]) {
        let yt_hint = m.keys().any(|k| {
            let k = k.to_ascii_lowercase();
            k.contains("youtube") || k.contains("channel") || k.contains("thumbnail") || k.contains("video")
        });
        if yt_hint && YT_ID.is_match(s) {
            return Some(s.clone());
        }
    }
    None
}

fn duration_secs(v: &Value) -> Option<u32> {
    let n = match v {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => return crate::models::parse_duration(s).or_else(|| s.parse::<f64>().ok().map(|f| f as u32)),
        _ => return None,
    };
    if n <= 0.0 {
        return None;
    }
    // Heuristic: anything above 10 hours is milliseconds.
    Some(if n > 36_000.0 { (n / 1000.0) as u32 } else { n as u32 })
}

fn track_from(m: &Map<String, Value>) -> Option<ImportItem> {
    let title = get_ci(m, &["title", "trackName", "songName", "trackTitle", "songTitle", "name", "song", "track"]).and_then(as_text);
    let artist = get_ci(m, &["artist", "artistName", "artists", "artistNames", "author", "creator", "channel", "channelTitle", "channelName", "uploader", "subtitle", "performer"])
        .and_then(as_text)
        .map(|a| a.trim_end_matches(" - Topic").to_string());
    let video_id = find_video_id(m);
    let album = get_ci(m, &["album", "albumName", "albumTitle", "collectionName"]).and_then(as_text);
    let duration = get_ci(m, &["duration", "durationSeconds", "lengthSeconds", "length", "durationMs", "duration_ms", "durationInSeconds"]).and_then(duration_secs);

    match (&title, &artist, &video_id) {
        (Some(_), Some(_), _) | (Some(_), None, Some(_)) | (None, _, Some(_)) => {}
        _ => return None,
    }
    // Containers (playlists/albums) also have a title — skip objects that hold lists of things.
    if video_id.is_none() && m.values().any(|v| matches!(v, Value::Array(a) if a.len() > 1 && a.iter().all(Value::is_object))) {
        return None;
    }

    let mut title = title.unwrap_or_default();
    let mut artist = artist.unwrap_or_default();
    if artist.is_empty() {
        if let Some((a, t)) = title.split_once(" - ") {
            (artist, title) = (a.trim().to_string(), t.trim().to_string());
        }
    }
    let provider_id = video_id.clone().unwrap_or_else(|| format!("{}|{}", artist.to_lowercase(), title.to_lowercase()));
    Some(ImportItem { provider_id, title, artist, album, duration, video_id })
}

fn walk(v: &Value, depth: usize, out: &mut Vec<ImportItem>) {
    if depth > MAX_DEPTH {
        return;
    }
    match v {
        Value::Object(m) => {
            if let Some(t) = track_from(m) {
                out.push(t);
                return;
            }
            for child in m.values() {
                walk(child, depth + 1, out);
            }
        }
        Value::Array(a) => a.iter().for_each(|c| walk(c, depth + 1, out)),
        // Embedded JSON strings (common in Core Data / UserDefaults blobs).
        Value::String(s) if s.len() > 20 && (s.starts_with('{') || s.starts_with('[')) => {
            if let Ok(inner) = serde_json::from_str::<Value>(s) {
                walk(&inner, depth + 1, out);
            }
        }
        _ => {}
    }
}

fn dedupe(items: &mut Vec<ImportItem>) {
    let mut seen = HashSet::new();
    items.retain(|i| seen.insert(i.provider_id.clone()));
}

fn parse_m3u(text: &str) -> Vec<ImportItem> {
    let mut out = Vec::new();
    let mut pending: Option<(Option<u32>, String)> = None;
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if let Some(info) = line.strip_prefix("#EXTINF:") {
            let (dur, name) = info.split_once(',').unwrap_or(("", info));
            pending = Some((dur.trim().parse::<i64>().ok().filter(|d| *d > 0).map(|d| d as u32), name.trim().to_string()));
        } else if !line.starts_with('#') {
            let (duration, name) = pending.take().unwrap_or((None, String::new()));
            let video_id = YT_URL.captures(line).map(|c| c[1].to_string());
            let fallback_name = line.rsplit(['/', '\\']).next().unwrap_or(line);
            let fallback_name = fallback_name.rsplit_once('.').map(|(n, _)| n).unwrap_or(fallback_name);
            let display = if name.is_empty() { urlencoding::decode(fallback_name).map(|s| s.into_owned()).unwrap_or_default() } else { name };
            let (artist, title) = display.split_once(" - ").map(|(a, t)| (a.trim().to_string(), t.trim().to_string())).unwrap_or((String::new(), display.clone()));
            if title.is_empty() && video_id.is_none() {
                continue;
            }
            out.push(ImportItem {
                provider_id: video_id.clone().unwrap_or_else(|| format!("{}|{}", artist.to_lowercase(), title.to_lowercase())),
                title,
                artist,
                album: None,
                duration,
                video_id,
            });
        }
    }
    out
}

// ---- plist ----------------------------------------------------------------------------

fn plist_to_json(v: &plist::Value) -> Value {
    use plist::Value as P;
    match v {
        P::Array(a) => Value::Array(a.iter().map(plist_to_json).collect()),
        P::Dictionary(d) => Value::Object(d.iter().map(|(k, v)| (k.clone(), plist_to_json(v))).collect()),
        P::Boolean(b) => Value::Bool(*b),
        P::Integer(i) => i.as_signed().map(Value::from).or_else(|| i.as_unsigned().map(Value::from)).unwrap_or(Value::Null),
        P::Real(f) => serde_json::Number::from_f64(*f).map(Value::Number).unwrap_or(Value::Null),
        P::String(s) => Value::String(s.clone()),
        P::Date(d) => Value::String(d.to_xml_format()),
        // Nested archives / JSON blobs are common inside Data fields.
        P::Data(bytes) => {
            if bytes.starts_with(b"bplist") {
                plist::Value::from_reader(Cursor::new(bytes)).map(|p| unarchive(plist_to_json(&p))).unwrap_or(Value::Null)
            } else if let Ok(v) = serde_json::from_slice::<Value>(bytes) {
                v
            } else {
                Value::Null
            }
        }
        P::Uid(u) => serde_json::json!({ "$uid": u.get() }),
        _ => Value::Null,
    }
}

/// Resolve an NSKeyedArchiver object graph into plain JSON; other plists pass through.
fn unarchive(v: Value) -> Value {
    let Some(objects) = v.get("$objects").and_then(Value::as_array) else { return v };
    if v.get("$archiver").and_then(Value::as_str) != Some("NSKeyedArchiver") {
        return v;
    }
    let Some(root) = v.get("$top").and_then(|t| t.get("root").or_else(|| t.as_object()?.values().next())) else { return v };

    fn resolve(v: &Value, objects: &[Value], depth: usize) -> Value {
        if depth > MAX_DEPTH {
            return Value::Null;
        }
        if let Some(uid) = v.get("$uid").and_then(Value::as_u64) {
            return match objects.get(uid as usize) {
                Some(Value::String(s)) if s == "$null" => Value::Null,
                Some(o) => resolve(o, objects, depth + 1),
                None => Value::Null,
            };
        }
        match v {
            Value::Object(m) => {
                if let (Some(Value::Array(keys)), Some(Value::Array(vals))) = (m.get("NS.keys"), m.get("NS.objects")) {
                    let mut out = Map::new();
                    for (k, val) in keys.iter().zip(vals) {
                        if let Value::String(ks) = resolve(k, objects, depth + 1) {
                            out.insert(ks, resolve(val, objects, depth + 1));
                        }
                    }
                    return Value::Object(out);
                }
                if let Some(Value::Array(vals)) = m.get("NS.objects") {
                    return Value::Array(vals.iter().map(|x| resolve(x, objects, depth + 1)).collect());
                }
                if let Some(s) = m.get("NS.string").or_else(|| m.get("NS.relative")) {
                    return resolve(s, objects, depth + 1);
                }
                if let Some(t) = m.get("NS.time") {
                    return t.clone();
                }
                Value::Object(
                    m.iter()
                        .filter(|(k, _)| k.as_str() != "$class")
                        .map(|(k, x)| (k.clone(), resolve(x, objects, depth + 1)))
                        .collect(),
                )
            }
            Value::Array(a) => Value::Array(a.iter().map(|x| resolve(x, objects, depth + 1)).collect()),
            other => other.clone(),
        }
    }
    resolve(root, objects, 0)
}

// ---- sqlite (Core Data stores) -----------------------------------------------------------

fn sqlite_to_json(bytes: &[u8]) -> anyhow::Result<Value> {
    let dir = std::env::temp_dir().join(format!("ytp-import-{}", uuid::Uuid::new_v4().simple()));
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("import.sqlite");
    std::fs::write(&path, bytes)?;
    let result = (|| -> anyhow::Result<Value> {
        let conn = rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        let mut db = Map::new();
        for t in tables {
            let mut stmt = conn.prepare(&format!("SELECT * FROM \"{}\" LIMIT 100000", t.replace('"', "\"\"")))?;
            let cols: Vec<String> = stmt
                .column_names()
                .iter()
                // Core Data prefixes attribute columns with Z ("ZTITLE"); strip it so key matching works.
                .map(|c| c.strip_prefix('Z').filter(|s| !s.is_empty() && !c.starts_with("Z_")).unwrap_or(c).to_string())
                .collect();
            let rows: Vec<Value> = stmt
                .query_map([], |r| {
                    let mut m = Map::new();
                    for (i, c) in cols.iter().enumerate() {
                        let v = match r.get_ref(i)? {
                            rusqlite::types::ValueRef::Null => Value::Null,
                            rusqlite::types::ValueRef::Integer(n) => Value::from(n),
                            rusqlite::types::ValueRef::Real(f) => Value::from(f),
                            rusqlite::types::ValueRef::Text(s) => Value::String(String::from_utf8_lossy(s).into_owned()),
                            rusqlite::types::ValueRef::Blob(b) => {
                                if b.starts_with(b"bplist") {
                                    plist::Value::from_reader(Cursor::new(b)).map(|p| unarchive(plist_to_json(&p))).unwrap_or(Value::Null)
                                } else {
                                    serde_json::from_slice(b).unwrap_or(Value::Null)
                                }
                            }
                        };
                        m.insert(c.clone(), v);
                    }
                    Ok(Value::Object(m))
                })?
                .collect::<Result<_, _>>()?;
            db.insert(t, Value::Array(rows));
        }
        Ok(Value::Object(db))
    })();
    let _ = std::fs::remove_dir_all(&dir);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_with_youtube_ids() {
        let j = br#"{"version":2,"library":{"songs":[
            {"id":"dQw4w9WgXcQ","title":"Never Gonna Give You Up","artist":{"name":"Rick Astley"},"thumbnailURL":"https://i.ytimg.com/x.jpg","duration":213},
            {"title":"Get Lucky","artists":["Daft Punk","Pharrell Williams"],"url":"https://music.youtube.com/watch?v=5NV6Rdv1a3I&feature=share"}
        ],"playlists":[{"name":"Mix","songs":[{"videoId":"dQw4w9WgXcQ","title":"Never Gonna Give You Up","artist":"Rick Astley"}]}]}}"#;
        let items = parse(j, "library.demus").unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].video_id.as_deref(), Some("dQw4w9WgXcQ"));
        assert_eq!(items[0].artist, "Rick Astley");
        assert_eq!(items[1].video_id.as_deref(), Some("5NV6Rdv1a3I"));
        assert_eq!(items[1].artist, "Daft Punk, Pharrell Williams");
    }

    #[test]
    fn keyed_archive_plist() {
        // Build a tiny NSKeyedArchiver graph: root = [ {title, artist, videoId} ]
        use plist::{Dictionary, Uid, Value as P};
        let mut song = Dictionary::new();
        song.insert("title".into(), P::Uid(Uid::new(4)));
        song.insert("artist".into(), P::Uid(Uid::new(5)));
        song.insert("videoId".into(), P::Uid(Uid::new(6)));
        let mut arr = Dictionary::new();
        arr.insert("NS.objects".into(), P::Array(vec![P::Uid(Uid::new(3))]));
        let objects = vec![
            P::String("$null".into()),
            P::Dictionary(arr),
            P::String("unused".into()),
            P::Dictionary(song),
            P::String("Numb".into()),
            P::String("Linkin Park".into()),
            P::String("kXYiU_JCYtU".into()),
        ];
        let mut top = Dictionary::new();
        top.insert("root".into(), P::Uid(Uid::new(1)));
        let mut root = Dictionary::new();
        root.insert("$archiver".into(), P::String("NSKeyedArchiver".into()));
        root.insert("$objects".into(), P::Array(objects));
        root.insert("$top".into(), P::Dictionary(top));
        let mut buf = Vec::new();
        P::Dictionary(root).to_writer_binary(&mut buf).unwrap();

        let items = parse(&buf, "export.demus").unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Numb");
        assert_eq!(items[0].artist, "Linkin Park");
        assert_eq!(items[0].video_id.as_deref(), Some("kXYiU_JCYtU"));
    }

    #[test]
    fn zipped_json_and_m3u() {
        let mut buf = Vec::new();
        {
            let mut w = zip::ZipWriter::new(Cursor::new(&mut buf));
            w.start_file("data/library.json", zip::write::SimpleFileOptions::default()).unwrap();
            std::io::Write::write_all(&mut w, br#"[{"songName":"Numb","artistName":"Linkin Park"}]"#).unwrap();
            w.finish().unwrap();
        }
        let items = parse(&buf, "backup.zip").unwrap();
        assert_eq!(items[0].artist, "Linkin Park");

        let m3u = "#EXTM3U\n#EXTINF:187,Linkin Park - Numb\nhttps://youtu.be/kXYiU_JCYtU\n#EXTINF:200,Daft Punk - One More Time\n/music/one.mp3\n";
        let items = parse(m3u.as_bytes(), "list.m3u").unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].video_id.as_deref(), Some("kXYiU_JCYtU"));
        assert_eq!(items[1].title, "One More Time");
    }

    #[test]
    fn sqlite_core_data() {
        let dir = std::env::temp_dir().join(format!("ytp-test-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("x.sqlite");
        {
            let c = rusqlite::Connection::open(&p).unwrap();
            c.execute_batch("PRAGMA journal_mode=DELETE; CREATE TABLE ZSONG (Z_PK INTEGER, ZTITLE TEXT, ZARTIST TEXT, ZVIDEOID TEXT); INSERT INTO ZSONG VALUES (1,'Numb','Linkin Park','kXYiU_JCYtU');").unwrap();
        }
        let bytes = std::fs::read(&p).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        let items = parse(&bytes, "Demus.sqlite").unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].video_id.as_deref(), Some("kXYiU_JCYtU"));
    }
}
