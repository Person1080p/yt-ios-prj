use std::{collections::HashMap, sync::Arc};

use serde::Serialize;
use tokio::sync::{broadcast, Mutex};

use crate::{
    config::Config,
    db::Db,
    services::{
        lastfm::LastFm,
        playback::PlaySession,
        plex::Plex,
        queue::Queue,
        tailscale::TailscaleInfo,
        ytdlp::YtDlp,
        ytmusic::YtMusic,
    },
};

/// Pushed to clients over Server-Sent Events so every device stays in sync.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ServerEvent {
    Queue { queue: Queue },
    Import { job_id: i64 },
    Scrobbled { video_id: String },
    Profile { active: String },
}

pub struct AppState {
    pub cfg: Config,
    pub db: Db,
    pub http: reqwest::Client,
    pub yt: YtMusic,
    pub ytdlp: YtDlp,
    pub plex: Plex,
    pub lastfm: LastFm,
    pub queue: Mutex<Queue>,
    pub sessions: Mutex<HashMap<String, PlaySession>>,
    pub events: broadcast::Sender<ServerEvent>,
    /// Spotify PKCE: state -> (verifier, redirect_uri)
    pub spotify_pkce: Mutex<HashMap<String, (String, String)>>,
    pub tailscale: Arc<Mutex<TailscaleInfo>>,
}

pub type SharedState = Arc<AppState>;

impl AppState {
    pub fn emit(&self, ev: ServerEvent) {
        let _ = self.events.send(ev);
    }
}
