//! Server-side play queue, shared by every connected device and persisted across restarts.

use serde::{Deserialize, Serialize};

use crate::{db::Db, models::Track, services::profile};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueItem {
    pub uid: String,
    pub track: Track,
    /// Added automatically by autoplay/radio rather than by the user.
    #[serde(default)]
    pub auto: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Queue {
    pub items: Vec<QueueItem>,
    pub index: usize,
    pub autoplay: bool,
    /// Bumped on every change so clients can ignore stale updates.
    #[serde(default)]
    pub version: u64,
    /// Which profile this queue belongs to.
    #[serde(default = "main_profile")]
    pub profile: String,
}

fn main_profile() -> String {
    profile::MAIN.to_string()
}

impl Default for Queue {
    fn default() -> Self {
        Self { items: vec![], index: 0, autoplay: true, version: 0, profile: main_profile() }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum InsertAt {
    /// Right after the current track.
    Next,
    /// After the current track *and* after any other "play next" items — i.e. before auto items.
    #[default]
    End,
    /// Replace the current track and start playing immediately.
    Now,
}

fn item(track: Track, auto: bool) -> QueueItem {
    QueueItem { uid: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(), track, auto }
}

impl Queue {
    /// Load the active profile's queue.
    pub async fn load(db: &Db) -> Self {
        let p = db.active_profile().await;
        Self::load_profile(db, &p).await
    }

    pub async fn load_profile(db: &Db, profile_name: &str) -> Self {
        let mut q: Self = db
            .get_setting(&profile::queue_key(profile_name))
            .await
            .ok()
            .flatten()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        q.profile = profile_name.to_string();
        q
    }

    pub async fn save(&mut self, db: &Db) -> anyhow::Result<()> {
        self.version += 1;
        db.set_setting(&profile::queue_key(&self.profile), &serde_json::to_string(self)?).await
    }

    #[cfg(test)]
    pub fn current(&self) -> Option<&QueueItem> {
        self.items.get(self.index)
    }

    pub fn remaining(&self) -> usize {
        self.items.len().saturating_sub(self.index + 1)
    }

    pub fn add(&mut self, tracks: Vec<Track>, at: InsertAt) {
        if tracks.is_empty() {
            return;
        }
        let new: Vec<QueueItem> = tracks.into_iter().map(|t| item(t, false)).collect();
        if self.items.is_empty() {
            self.items = new;
            self.index = 0;
            return;
        }
        match at {
            InsertAt::Next => {
                let pos = (self.index + 1).min(self.items.len());
                self.items.splice(pos..pos, new);
            }
            InsertAt::Now => {
                let pos = (self.index + 1).min(self.items.len());
                self.items.splice(pos..pos, new);
                self.index = pos;
            }
            InsertAt::End => {
                // User-added tracks go before the auto-generated tail.
                let mut pos = self.items.len();
                while pos > self.index + 1 && self.items[pos - 1].auto {
                    pos -= 1;
                }
                self.items.splice(pos..pos, new);
            }
        }
    }

    pub fn replace(&mut self, tracks: Vec<Track>, index: usize) {
        self.items = tracks.into_iter().map(|t| item(t, false)).collect();
        self.index = index.min(self.items.len().saturating_sub(1));
    }

    pub fn append_auto(&mut self, tracks: Vec<Track>) {
        let existing: std::collections::HashSet<_> = self.items.iter().map(|i| i.track.video_id.clone()).collect();
        self.items.extend(tracks.into_iter().filter(|t| !existing.contains(&t.video_id)).map(|t| item(t, true)));
    }

    pub fn move_item(&mut self, from: usize, to: usize) {
        if from >= self.items.len() || to >= self.items.len() || from == to {
            return;
        }
        let it = self.items.remove(from);
        self.items.insert(to, it);
        // Keep the playing track playing.
        if self.index == from {
            self.index = to;
        } else if from < self.index && to >= self.index {
            self.index -= 1;
        } else if from > self.index && to <= self.index {
            self.index += 1;
        }
    }

    pub fn remove(&mut self, uid: &str) {
        let Some(pos) = self.items.iter().position(|i| i.uid == uid) else { return };
        self.items.remove(pos);
        if pos < self.index {
            self.index -= 1;
        }
        if self.index >= self.items.len() {
            self.index = self.items.len().saturating_sub(1);
        }
    }

    /// Drop everything except the current track.
    pub fn clear_upcoming(&mut self) {
        self.items.truncate(self.index + 1);
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.index = 0;
    }

    pub fn shuffle_upcoming(&mut self) {
        use rand::seq::SliceRandom;
        let start = (self.index + 1).min(self.items.len());
        self.items[start..].shuffle(&mut rand::thread_rng());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str) -> Track {
        Track { video_id: id.into(), title: id.into(), artist: String::new(), album: None, duration: None, thumbnail: None }
    }
    fn ids(q: &Queue) -> Vec<&str> {
        q.items.iter().map(|i| i.track.video_id.as_str()).collect()
    }

    #[test]
    fn insert_positions() {
        let mut q = Queue::default();
        q.add(vec![t("a"), t("b")], InsertAt::End);
        q.append_auto(vec![t("r1"), t("r2")]);
        q.add(vec![t("c")], InsertAt::End);
        assert_eq!(ids(&q), ["a", "b", "c", "r1", "r2"]);
        q.add(vec![t("n")], InsertAt::Next);
        assert_eq!(ids(&q), ["a", "n", "b", "c", "r1", "r2"]);
        q.add(vec![t("now")], InsertAt::Now);
        assert_eq!(q.current().unwrap().track.video_id, "now");
    }

    #[test]
    fn move_keeps_current() {
        let mut q = Queue::default();
        q.add(vec![t("a"), t("b"), t("c")], InsertAt::End);
        q.index = 1;
        q.move_item(2, 0);
        assert_eq!(ids(&q), ["c", "a", "b"]);
        assert_eq!(q.current().unwrap().track.video_id, "b");
    }
}
