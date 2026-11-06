use serde::{Deserialize, Serialize};

/// A playable track. `video_id` is the YouTube video id and acts as the canonical key everywhere;
/// Plex is used as an alternative *source* for the same logical track.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub video_id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: Option<String>,
    /// Seconds.
    #[serde(default)]
    pub duration: Option<u32>,
    #[serde(default)]
    pub thumbnail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HomeItem {
    /// song | video | playlist | album | artist
    pub kind: String,
    pub title: String,
    pub subtitle: String,
    pub thumbnail: Option<String>,
    pub video_id: Option<String>,
    pub playlist_id: Option<String>,
    pub browse_id: Option<String>,
    /// Present for `song`/`video` items so the client can play them directly.
    pub track: Option<Track>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shelf {
    pub title: String,
    pub items: Vec<HomeItem>,
}

/// Search across everything (not just songs): the best match, then results by kind.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SearchResults {
    pub top: Option<HomeItem>,
    pub songs: Vec<Track>,
    pub artists: Vec<HomeItem>,
    pub albums: Vec<HomeItem>,
    pub playlists: Vec<HomeItem>,
    pub videos: Vec<Track>,
}

/// A YouTube Music page reference (e.g. an artist's full discography).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseRef {
    pub browse_id: String,
    pub params: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistShelf {
    pub title: String,
    pub items: Vec<HomeItem>,
    /// "See all": a grid page (discography) or a playlist.
    pub more: Option<BrowseRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistPage {
    pub id: String,
    pub name: String,
    pub thumbnail: Option<String>,
    pub description: Option<String>,
    /// e.g. "205M monthly audience" / "5.46M subscribers"
    pub stats: Option<String>,
    /// The artist's radio (YouTube Music "Mix").
    pub radio_playlist_id: Option<String>,
    pub top_songs: Vec<Track>,
    /// Playlist with all their songs ("See all" under Top songs).
    pub songs_playlist_id: Option<String>,
    /// Albums, Singles & EPs, Videos, Fans might also like, Featured on, …
    pub shelves: Vec<ArtistShelf>,
}

/// A grid of albums/singles (an artist's discography).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GridPage {
    pub title: String,
    pub items: Vec<HomeItem>,
}

/// An item coming from an external provider during an import, before it is matched to YouTube.
#[derive(Debug, Clone)]
pub struct ImportItem {
    pub provider_id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration: Option<u32>,
    pub video_id: Option<String>,
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// "3:45" / "1:02:03" -> seconds
pub fn parse_duration(s: &str) -> Option<u32> {
    let s = s.trim();
    if s.is_empty() || !s.chars().all(|c| c.is_ascii_digit() || c == ':') {
        return None;
    }
    let mut total = 0u32;
    for part in s.split(':') {
        total = total.checked_mul(60)?.checked_add(part.parse::<u32>().ok()?)?;
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn durations() {
        assert_eq!(parse_duration("3:45"), Some(225));
        assert_eq!(parse_duration("1:02:03"), Some(3723));
        assert_eq!(parse_duration("Song"), None);
    }
}
