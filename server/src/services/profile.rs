//! Listener profiles: your normal one ("main") and a "fresh" one that starts with no history.
//!
//! The fresh profile talks to YouTube Music as a brand-new anonymous visitor (its own
//! visitor id, never your Google sign-in), keeps its own play history and queue, and never
//! scrobbles to Last.fm or reports to YouTube — so recommendations start from zero, learn only
//! from what's played in this profile, and your real history stays untouched. Library,
//! playlists, Plex and settings are shared.

pub const PROFILE_KEY: &str = "profile.active";
pub const FRESH_VISITOR_KEY: &str = "profile.fresh.visitor";
pub const FRESH_STARTED_KEY: &str = "profile.fresh.started";
pub const MAIN: &str = "main";
pub const FRESH: &str = "fresh";

/// Settings key holding a profile's queue.
pub fn queue_key(profile: &str) -> String {
    if profile == MAIN { "queue.state".into() } else { format!("queue.state.{profile}") }
}
