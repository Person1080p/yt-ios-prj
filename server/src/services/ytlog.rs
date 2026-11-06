//! Optional log of every request this server makes to YouTube: InnerTube API calls, cache
//! hits, rate-limit pauses, history pings, yt-dlp runs and artwork downloads.
//!
//! Turned on from Settings → Diagnostics. Entries go to `<data>/logs/youtube.log` (one line
//! each, rotated at 5 MB) and to an in-memory ring that powers the stats shown in Settings.
//! Every entry records *who* asked (the API route, or the background job), which is what
//! tells you whether something is calling YouTube too often.

use std::{
    collections::{BTreeMap, VecDeque},
    future::Future,
    io::Write,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, OnceLock,
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use serde::Serialize;

pub const PREF: &str = "prefs.log_youtube";
const RING: usize = 5000;
const MAX_FILE: u64 = 5 * 1024 * 1024;

static ENABLED: AtomicBool = AtomicBool::new(false);
static PATH: OnceLock<PathBuf> = OnceLock::new();
static RECENT: Mutex<VecDeque<Entry>> = Mutex::new(VecDeque::new());
static WRITER: OnceLock<tokio::sync::mpsc::UnboundedSender<String>> = OnceLock::new();

tokio::task_local! {
    static ORIGIN: String;
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Unix time in milliseconds.
    pub ts: i64,
    /// innertube | cache | cooldown | history | ytdlp | art | playerjs
    pub kind: &'static str,
    /// e.g. "search", "next", "player", "browse", "resolve", "song_info"
    pub endpoint: String,
    /// Query, video id, browse id…
    pub detail: String,
    /// The API route or background job that caused the request.
    pub origin: String,
    /// ok | hit | stale | timeout | rate-limited | http-error | network-error | error | waited
    pub outcome: String,
    pub status: Option<u16>,
    pub ms: u64,
    pub attempt: u32,
    pub error: Option<String>,
}

/// Set up the log file location and the background writer. Call once at startup.
pub fn init(data_dir: &std::path::Path, enabled: bool) {
    let dir = data_dir.join("logs");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("youtube.log");
    let _ = PATH.set(path.clone());
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let _ = WRITER.set(tx);
    tokio::task::spawn_blocking(move || {
        while let Some(line) = rx.blocking_recv() {
            if std::fs::metadata(&path).map(|m| m.len() > MAX_FILE).unwrap_or(false) {
                let _ = std::fs::rename(&path, path.with_extension("log.1"));
            }
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                let _ = f.write_all(line.as_bytes());
            }
        }
    });
    set_enabled(enabled);
}

pub fn set_enabled(on: bool) {
    let was = ENABLED.swap(on, Ordering::Relaxed);
    if on && !was {
        write_line(format!("{}  ---- logging started ----\n", iso(now_ms())));
    }
}

pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

pub fn path() -> Option<PathBuf> {
    PATH.get().cloned()
}

// ---- who's asking -------------------------------------------------------------------

/// Run `fut` with requests attributed to `label` (an API route or a background job).
pub async fn with_origin<F: Future>(label: impl Into<String>, fut: F) -> F::Output {
    ORIGIN.scope(label.into(), fut).await
}

pub fn origin() -> String {
    ORIGIN.try_with(|o| o.clone()).unwrap_or_else(|_| "background".into())
}

/// Whether the current work is someone waiting on an API response (vs. a background job).
pub fn is_interactive() -> bool {
    ORIGIN
        .try_with(|o| ["GET ", "POST ", "PUT ", "DELETE "].iter().any(|m| o.starts_with(m)) && !o.contains('→'))
        .unwrap_or(false)
}

/// `tokio::spawn` that keeps the current attribution, with `suffix` appended (e.g. "autofill").
pub fn spawn<F>(suffix: &str, fut: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    let label = format!("{} → {suffix}", origin());
    tokio::spawn(with_origin(label, fut))
}

// ---- recording ----------------------------------------------------------------------

/// Times one request; call [`Timer::done`] when it finishes.
pub struct Timer {
    kind: &'static str,
    endpoint: String,
    detail: String,
    start: Instant,
}

pub fn start(kind: &'static str, endpoint: impl Into<String>, detail: impl Into<String>) -> Timer {
    Timer { kind, endpoint: endpoint.into(), detail: detail.into(), start: Instant::now() }
}

impl Timer {
    pub fn done(self, outcome: &str, status: Option<u16>, attempt: u32, error: Option<String>) {
        if !enabled() {
            return;
        }
        record(Entry {
            ts: now_ms(),
            kind: self.kind,
            endpoint: self.endpoint,
            detail: self.detail,
            origin: origin(),
            outcome: outcome.to_string(),
            status,
            ms: self.start.elapsed().as_millis() as u64,
            attempt,
            error,
        });
    }
}

/// A response served from the server-side cache (no request sent to YouTube).
pub fn cache_event(key: &str, outcome: &str) {
    if !enabled() || !key.starts_with("yt:") {
        return;
    }
    // yt:{profile}:{signed}:{kind}:{arg}
    let mut parts = key.splitn(5, ':');
    let (_, _, _, kind, arg) = (parts.next(), parts.next(), parts.next(), parts.next(), parts.next());
    record(Entry {
        ts: now_ms(),
        kind: "cache",
        endpoint: kind.unwrap_or_default().to_string(),
        detail: arg.unwrap_or_default().to_string(),
        origin: origin(),
        outcome: outcome.to_string(),
        status: None,
        ms: 0,
        attempt: 0,
        error: None,
    });
}

fn record(e: Entry) {
    let line = format!(
        "{}  {:<9} {:<12} {:<13} {:>3} {:>6}ms  try={}  from=\"{}\"  {}{}\n",
        iso(e.ts),
        e.kind,
        e.endpoint,
        e.outcome,
        e.status.map(|s| s.to_string()).unwrap_or_else(|| "-".into()),
        e.ms,
        e.attempt,
        e.origin,
        e.detail,
        e.error.as_deref().map(|x| format!("  error=\"{}\"", x.replace('\n', " "))).unwrap_or_default(),
    );
    write_line(line);
    let mut r = RECENT.lock().unwrap_or_else(|p| p.into_inner());
    if r.len() >= RING {
        r.pop_front();
    }
    r.push_back(e);
}

fn write_line(line: String) {
    if let Some(tx) = WRITER.get() {
        let _ = tx.send(line);
    }
}

/// Forget the in-memory entries and empty the file.
pub fn clear() {
    RECENT.lock().unwrap_or_else(|p| p.into_inner()).clear();
    if let Some(p) = PATH.get() {
        let _ = std::fs::write(p, b"");
        let _ = std::fs::remove_file(p.with_extension("log.1"));
    }
}

// ---- stats ------------------------------------------------------------------------

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    /// Requests actually sent to YouTube (excludes cache hits).
    pub requests: usize,
    pub cache_hits: usize,
    pub timeouts: usize,
    pub rate_limited: usize,
    pub errors: usize,
    pub avg_ms: u64,
    pub max_ms: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub last_minute: Window,
    pub last_10_minutes: Window,
    pub last_hour: Window,
    /// Most requests sent within any single minute of the last hour.
    pub peak_per_minute: usize,
    /// Last hour: requests by "kind endpoint".
    pub by_endpoint: Vec<(String, usize)>,
    /// Last hour: requests by origin.
    pub by_origin: Vec<(String, usize)>,
    /// Last hour: the same request (endpoint + detail) sent more than twice.
    pub repeated: Vec<(String, usize)>,
}

fn is_request(e: &Entry) -> bool {
    !matches!(e.kind, "cache" | "cooldown")
}

fn window(entries: &[&Entry], since: i64) -> Window {
    let mut w = Window::default();
    let mut total_ms = 0u64;
    for e in entries.iter().filter(|e| e.ts >= since) {
        if e.kind == "cache" {
            w.cache_hits += 1;
            continue;
        }
        if !is_request(e) {
            continue;
        }
        w.requests += 1;
        total_ms += e.ms;
        w.max_ms = w.max_ms.max(e.ms);
        match e.outcome.as_str() {
            "timeout" => w.timeouts += 1,
            "rate-limited" => w.rate_limited += 1,
            "ok" => {}
            _ => w.errors += 1,
        }
    }
    if w.requests > 0 {
        w.avg_ms = total_ms / w.requests as u64;
    }
    w
}

fn top(map: BTreeMap<String, usize>, min: usize) -> Vec<(String, usize)> {
    let mut v: Vec<_> = map.into_iter().filter(|(_, n)| *n >= min).collect();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    v.truncate(15);
    v
}

pub fn stats() -> Stats {
    let r = RECENT.lock().unwrap_or_else(|p| p.into_inner());
    let now = now_ms();
    let hour: Vec<&Entry> = r.iter().filter(|e| e.ts >= now - 3_600_000).collect();
    let mut per_min: BTreeMap<i64, usize> = BTreeMap::new();
    let mut by_endpoint = BTreeMap::new();
    let mut by_origin = BTreeMap::new();
    let mut repeated = BTreeMap::new();
    for e in hour.iter().filter(|e| is_request(e)) {
        *per_min.entry(e.ts / 60_000).or_default() += 1;
        *by_endpoint.entry(format!("{} {}", e.kind, e.endpoint)).or_default() += 1;
        *by_origin.entry(e.origin.clone()).or_default() += 1;
        if !e.detail.is_empty() {
            *repeated.entry(format!("{} {}", e.endpoint, e.detail)).or_default() += 1;
        }
    }
    Stats {
        last_minute: window(&hour, now - 60_000),
        last_10_minutes: window(&hour, now - 600_000),
        last_hour: window(&hour, 0),
        peak_per_minute: per_min.values().copied().max().unwrap_or(0),
        by_endpoint: top(by_endpoint, 1),
        by_origin: top(by_origin, 1),
        repeated: top(repeated, 3),
    }
}

/// Newest first.
pub fn recent(limit: usize) -> Vec<Entry> {
    let r = RECENT.lock().unwrap_or_else(|p| p.into_inner());
    r.iter().rev().take(limit).cloned().collect()
}

// ---- time ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// UTC "YYYY-MM-DDTHH:MM:SS.mmmZ".
fn iso(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (y, m, d) = crate::services::ytmusic::civil_from_days(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z", sod / 3600, sod % 3600 / 60, sod % 60, ms.rem_euclid(1000))
}

#[cfg(test)]
mod tests {
    #[test]
    fn iso_format() {
        assert_eq!(super::iso(1_700_000_000_123), "2023-11-14T22:13:20.123Z");
    }
}
