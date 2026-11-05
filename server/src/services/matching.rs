//! Fuzzy matching of "artist - title" pairs across providers.

use std::sync::LazyLock;

use regex::Regex;

static BRACKETS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)[\(\[][^\)\]]*(official|video|audio|lyric|lyrics|visuali[sz]er|remaster(ed)?|explicit|clean|hd|hq|4k|mv|m/v|feat\.?|ft\.?|with |prod\.?|from |version|edit)[^\)\]]*[\)\]]",
    )
    .unwrap()
});
static FEAT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\s+(feat\.?|ft\.?|featuring)\s+.*$").unwrap());
static DASH_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\s+-\s+(\d{4}\s+)?remaster(ed)?.*$|\s+-\s+(radio|single|album) (edit|version).*$").unwrap());
static NON_ALNUM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^\p{L}\p{N}]+").unwrap());

/// Lowercase, strip decorations like "(Official Video)", "feat. X", punctuation.
pub fn normalize(s: &str) -> String {
    let s = BRACKETS.replace_all(s, " ");
    let s = FEAT.replace(&s, "");
    let s = DASH_SUFFIX.replace(&s, "");
    let s = s.to_lowercase().replace('&', " and ").replace(" - topic", "");
    NON_ALNUM.replace_all(&s, " ").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// First listed artist ("A, B & C" -> "a").
pub fn primary_artist(s: &str) -> String {
    let first = s
        .split([',', ';', '/'])
        .next()
        .unwrap_or(s)
        .split(" & ")
        .next()
        .unwrap_or(s)
        .split(" x ")
        .next()
        .unwrap_or(s);
    normalize(first)
}

/// Similarity in 0..=1 between two already-normalized strings.
pub fn similarity(a: &str, b: &str) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    if a.contains(b) || b.contains(a) {
        let (short, long) = if a.len() < b.len() { (a, b) } else { (b, a) };
        return 0.7 + 0.25 * (short.len() as f32 / long.len() as f32);
    }
    let ta: std::collections::HashSet<&str> = a.split(' ').collect();
    let tb: std::collections::HashSet<&str> = b.split(' ').collect();
    let inter = ta.intersection(&tb).count() as f32;
    let union = ta.union(&tb).count() as f32;
    if union == 0.0 { 0.0 } else { inter / union }
}

/// Score how well a candidate matches a wanted track. Returns 0..=1.
pub fn score(
    want_title: &str,
    want_artist: &str,
    want_duration: Option<u32>,
    cand_title: &str,
    cand_artist: &str,
    cand_duration: Option<u32>,
) -> f32 {
    let wt = normalize(want_title);
    let ct = normalize(cand_title);
    let title = similarity(&wt, &ct);

    let wa = primary_artist(want_artist);
    let ca_full = normalize(cand_artist);
    // Candidate artist strings are often "A, B & C"; accept if the wanted primary artist is in there.
    let artist = if !wa.is_empty() && ca_full.contains(&wa) {
        1.0
    } else {
        similarity(&wa, &primary_artist(cand_artist))
            // YouTube uploads often put the artist in the title: "Artist - Song"
            .max(if !wa.is_empty() && ct.contains(&wa) { 0.8 } else { 0.0 })
    };

    let mut s = title * 0.6 + artist * 0.4;
    if let (Some(a), Some(b)) = (want_duration, cand_duration) {
        let diff = (a as i64 - b as i64).abs();
        if diff <= 3 {
            s += 0.1;
        } else if diff > 20 {
            s -= 0.25;
        }
    }
    s.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes() {
        assert_eq!(normalize("Blinding Lights (Official Video)"), "blinding lights");
        assert_eq!(normalize("Song Name feat. Someone"), "song name");
        assert_eq!(normalize("Hey Jude - Remastered 2015"), "hey jude");
        assert_eq!(primary_artist("Daft Punk, Pharrell Williams"), "daft punk");
    }

    #[test]
    fn scores() {
        assert!(score("Get Lucky", "Daft Punk", Some(248), "Get Lucky (feat. Pharrell Williams)", "Daft Punk, Pharrell Williams", Some(249)) > 0.9);
        assert!(score("Get Lucky", "Daft Punk", Some(248), "Lose Yourself", "Eminem", Some(320)) < 0.3);
    }
}
