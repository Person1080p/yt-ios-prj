// Audio engine. The queue lives on the server (shared by all devices); this module
// owns the <audio> element on *this* device, follows the queue's current item,
// reports listening progress (scrobbles / YouTube history) and drives the Media Session.
//
// Direct mode streams `/api/stream/:id` by URL (with Range/seeking).
// In-page tailnet mode can't hand a URL to <audio>, so each track is downloaded over
// the tailnet into a Blob, and the next track is prefetched — which also keeps
// auto-advance working while iOS has the app in the background.

import { api, fetchAudio, randomId, streamUrl, type InsertAt, type Queue, type QueueItem, type Track } from "./api";
import { useStore } from "./store";
import { apiFetch, detectConnection, isTailnet } from "./transport";
import { loadProfile } from "./profile";

const audio = new Audio();
audio.preload = "auto";
(audio as HTMLAudioElement & { playsInline?: boolean }).playsInline = true;

let loadedUid: string | null = null;
/** Track primed synchronously inside a user gesture, before the server confirmed the queue change. */
let pendingVideoId: string | null = null;
let sessionId = "";
let sessionTrack: Track | null = null;
let lastReportAt = 0;
let triedFallback = false;
let loadToken = 0;
let warmTimer: ReturnType<typeof setTimeout> | undefined;

const set = useStore.setState;
const get = useStore.getState;

function current(): QueueItem | undefined {
  const q = get().queue;
  return q ? q.items[q.index] : undefined;
}

// ---- iOS autoplay unlock ---------------------------------------------------------------
// Playing anything from inside a tap "unlocks" the element so later async play() calls work.

let silentUrl: string | null = null;
let unlocked = false;
function silent() {
  if (!silentUrl) {
    const n = 800;
    const b = new ArrayBuffer(44 + n * 2);
    const v = new DataView(b);
    const w = (o: number, s: string) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
    w(0, "RIFF"); v.setUint32(4, 36 + n * 2, true); w(8, "WAVE"); w(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, 8000, true); v.setUint32(28, 16000, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    w(36, "data"); v.setUint32(40, n * 2, true);
    silentUrl = URL.createObjectURL(new Blob([b], { type: "audio/wav" }));
  }
  return silentUrl;
}
const isSilent = () => !!silentUrl && audio.src === silentUrl;
function unlockAudio() {
  if (unlocked) return;
  unlocked = true;
  audio.src = silent();
  audio.play().catch(() => {});
}

// ---- tailnet audio blobs -----------------------------------------------------------------

type Loaded = { url: string; source: "plex" | "youtube" | null };
const blobs = new Map<string, Loaded>();
const inflight = new Map<string, Promise<Loaded>>();

function loadBlob(videoId: string, via?: "pipe"): Promise<Loaded> {
  const key = videoId + (via ?? "");
  const hit = blobs.get(key);
  if (hit) {
    blobs.delete(key); // refresh LRU position
    blobs.set(key, hit);
    return Promise.resolve(hit);
  }
  const running = inflight.get(key);
  if (running) return running;
  const p = fetchAudio(videoId, via)
    .then(async (r) => {
      if (!r.ok) throw new Error(`stream failed (${r.status})`);
      const source = (r.headers.get("x-audio-source") as Loaded["source"]) ?? null;
      const type = r.headers.get("content-type") ?? "audio/mp4";
      const blob = new Blob([await r.arrayBuffer()], { type });
      const loaded = { url: URL.createObjectURL(blob), source };
      blobs.set(key, loaded);
      // Keep a few tracks around; never revoke the one that's playing.
      for (const [k, v] of blobs) {
        if (blobs.size <= 4) break;
        if (v.url !== audio.src) {
          URL.revokeObjectURL(v.url);
          blobs.delete(k);
        }
      }
      return loaded;
    })
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

// ---- reporting -------------------------------------------------------------------------

function report(event: "start" | "progress" | "end") {
  if (!sessionTrack || !sessionId) return;
  lastReportAt = Date.now();
  api
    .playback({
      sessionId,
      track: sessionTrack,
      event,
      position: audio.currentTime || 0,
      duration: isFinite(audio.duration) ? audio.duration : undefined,
      source: get().source,
    })
    .catch(() => {});
}

function beginSession(track: Track) {
  if (sessionTrack) report("end");
  sessionId = randomId();
  sessionTrack = track;
  lastReportAt = 0;
}

// ---- loading ---------------------------------------------------------------------------

function setSrc(track: Track, autoplay: boolean) {
  triedFallback = false;
  const token = ++loadToken;
  set({ source: null, position: 0, duration: track.duration ?? 0, buffering: true });
  updateMediaSession(track);
  scheduleWarmNext();

  if (!isTailnet()) {
    audio.src = streamUrl(track.videoId);
    if (autoplay) audio.play().catch(() => {});
    api
      .source(track.videoId)
      .then((s) => token === loadToken && set({ source: s.source }))
      .catch(() => {});
    return;
  }

  loadBlob(track.videoId)
    .then((l) => {
      if (token !== loadToken) return;
      lastReportAt = 0;
      audio.src = l.url;
      set({ source: l.source });
      if (autoplay) audio.play().catch(() => {});
      else set({ buffering: false });
    })
    .catch((e) => {
      if (token !== loadToken) return;
      get().toastMsg(`Couldn't load “${track.title}”: ${(e as Error).message}`);
      set({ buffering: false });
    });
}

/** Call inside a click handler so mobile browsers allow playback to start. */
function prime(track: Track) {
  pendingVideoId = track.videoId;
  if (isTailnet()) unlockAudio();
  beginSession(track);
  setSrc(track, true);
}

let followedProfile: string | undefined;

function follow(q: Queue | null) {
  // Switching listener profile swaps the whole queue: stop rather than jump into the other profile's track.
  const profileChanged = !!q && followedProfile !== undefined && q.profile !== followedProfile;
  if (q) followedProfile = q.profile;
  if (profileChanged) audio.pause();
  const item = q ? q.items[q.index] : undefined;
  if (!item) {
    if (loadedUid) {
      audio.pause();
      audio.removeAttribute("src");
      audio.load();
      loadedUid = null;
      if (sessionTrack) report("end");
      sessionTrack = null;
      set({ playing: false, position: 0, duration: 0, source: null });
    }
    return;
  }
  if (item.uid === loadedUid) return;
  if (pendingVideoId && item.track.videoId === pendingVideoId) {
    // Already loading it from the user gesture.
    pendingVideoId = null;
    loadedUid = item.uid;
    return;
  }
  const wasPlaying = !audio.paused && !profileChanged;
  loadedUid = item.uid;
  beginSession(item.track);
  setSrc(item.track, wasPlaying);
}

useStore.subscribe((s, prev) => {
  if (s.queue !== prev.queue) follow(s.queue);
});

/** Get the next track ready ahead of time so transitions are near-gapless. */
function scheduleWarmNext() {
  clearTimeout(warmTimer);
  warmTimer = setTimeout(
    () => {
      const q = get().queue;
      const next = q?.items[q.index + 1];
      if (!next) return;
      if (isTailnet()) {
        loadBlob(next.track.videoId).catch(() => {});
      } else {
        // Makes the server resolve the stream URL with yt-dlp now rather than at transition time.
        fetch(streamUrl(next.track.videoId), { headers: { Range: "bytes=0-1" } })
          .then((r) => r.body?.cancel())
          .catch(() => {});
      }
    },
    isTailnet() ? 3000 : 8000,
  );
}

// ---- audio events ------------------------------------------------------------------------

audio.addEventListener("playing", () => {
  if (isSilent()) return;
  set({ playing: true, buffering: false });
  if (lastReportAt === 0) report("start");
});
audio.addEventListener("pause", () => !isSilent() && set({ playing: false }));
audio.addEventListener("waiting", () => !isSilent() && set({ buffering: true }));
audio.addEventListener("canplay", () => set({ buffering: false }));
audio.addEventListener("durationchange", () => {
  if (!isSilent() && isFinite(audio.duration)) set({ duration: audio.duration });
});
audio.addEventListener("timeupdate", () => {
  if (isSilent()) return;
  set({ position: audio.currentTime });
  if (!audio.paused && Date.now() - lastReportAt > 15000) report("progress");
  if ("mediaSession" in navigator && isFinite(audio.duration) && audio.duration > 0) {
    try {
      navigator.mediaSession.setPositionState({
        duration: audio.duration,
        position: Math.min(audio.currentTime, audio.duration),
        playbackRate: audio.playbackRate,
      });
    } catch {
      /* ignore */
    }
  }
});
audio.addEventListener("ended", () => {
  if (isSilent()) return;
  report("end");
  sessionTrack = null;
  next(true);
});
audio.addEventListener("error", () => {
  const it = current();
  if (!it || !audio.src || isSilent()) return;
  if (!triedFallback) {
    // Retry through yt-dlp's pipe mode (no seeking, but robust).
    triedFallback = true;
    const token = loadToken;
    if (isTailnet()) {
      loadBlob(it.track.videoId, "pipe")
        .then((l) => {
          if (token !== loadToken) return;
          audio.src = l.url;
          audio.play().catch(() => {});
        })
        .catch(() => next(true));
    } else {
      // The page's address may have stopped reaching the server (e.g. left home Wi-Fi):
      // re-check, and reload this track over the Tailscale fallback if that's now in use.
      const at = audio.currentTime;
      detectConnection(true).then((c) => {
        if (token !== loadToken) return;
        if (c?.mode === "tailnet") {
          setSrc(it.track, true);
          if (at > 0) audio.addEventListener("loadedmetadata", () => (audio.currentTime = at), { once: true });
          return;
        }
        audio.src = streamUrl(it.track.videoId, "pipe");
        audio.play().catch(() => {});
      });
    }
    return;
  }
  get().toastMsg(`Couldn't play “${it.track.title}”, skipping`);
  next(true);
});

// ---- media session (lock screen / headphones / car) ---------------------------------------

function updateMediaSession(t: Track) {
  if (!("mediaSession" in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: t.title,
    artist: t.artist,
    album: t.album ?? "",
    artwork: t.thumbnail ? [{ src: t.thumbnail, sizes: "544x544", type: "image/jpeg" }] : [],
  });
}

if ("mediaSession" in navigator) {
  const ms = navigator.mediaSession;
  ms.setActionHandler("play", () => play());
  ms.setActionHandler("pause", () => pause());
  ms.setActionHandler("previoustrack", () => previous());
  ms.setActionHandler("nexttrack", () => next(true));
  ms.setActionHandler("seekto", (d) => d.seekTime != null && seek(d.seekTime));
  ms.setActionHandler("seekbackward", (d) => seek(audio.currentTime - (d.seekOffset ?? 10)));
  ms.setActionHandler("seekforward", (d) => seek(audio.currentTime + (d.seekOffset ?? 10)));
}

// ---- public controls ------------------------------------------------------------------------

async function apply(p: Promise<Queue>) {
  try {
    get().setQueue(await p);
  } catch (e) {
    pendingVideoId = null;
    get().toastMsg((e as Error).message);
  }
}

export function play() {
  const it = current();
  if (!it) return;
  if (isTailnet()) unlockAudio();
  if (it.uid !== loadedUid || isSilent() || !audio.src) {
    loadedUid = it.uid;
    beginSession(it.track);
    setSrc(it.track, true);
    return;
  }
  audio.play().catch(() => {});
}

export function pause() {
  audio.pause();
}

export function toggle() {
  if (audio.paused) play();
  else pause();
}

export function seek(t: number) {
  if (!isFinite(t)) return;
  audio.currentTime = Math.max(0, Math.min(t, isFinite(audio.duration) ? audio.duration - 0.5 : t));
}

export function next(auto = false) {
  const q = get().queue;
  if (!q) return;
  const n = q.items[q.index + 1];
  if (!n) {
    if (!auto) get().toastMsg("End of queue");
    audio.pause();
    return;
  }
  prime(n.track);
  apply(api.queue.setIndex(q.index + 1));
}

export function previous() {
  const q = get().queue;
  if (!q) return;
  if (audio.currentTime > 4 || q.index === 0) {
    seek(0);
    return;
  }
  prime(q.items[q.index - 1].track);
  apply(api.queue.setIndex(q.index - 1));
}

export function jumpTo(index: number) {
  const q = get().queue;
  const it = q?.items[index];
  if (!it) return;
  prime(it.track);
  apply(api.queue.setIndex(index));
}

/** Replace the queue with `tracks` and start at `index`. */
export function playTracks(tracks: Track[], index = 0) {
  if (!tracks.length) return;
  prime(tracks[index]);
  apply(api.queue.replace(tracks, index));
}

/** Play a single track followed by an automatic radio (YouTube Music + Last.fm). */
export function playRadio(track: Track) {
  prime(track);
  apply(api.queue.radio(track));
}

export function enqueue(tracks: Track[], at: InsertAt = "end") {
  if (!tracks.length) return;
  const wasEmpty = !get().queue?.items.length;
  if (at === "now" || wasEmpty) prime(tracks[0]);
  apply(api.queue.add(tracks, at));
  if (at === "next") get().toastMsg(tracks.length > 1 ? `${tracks.length} tracks will play next` : "Playing next");
  if (at === "end" && !wasEmpty) get().toastMsg(tracks.length > 1 ? `Added ${tracks.length} tracks to queue` : "Added to queue");
}

export function queueOp(p: Promise<Queue>) {
  return apply(p);
}

// ---- sync with server --------------------------------------------------------------------------

/** Server-sent events over apiFetch, so it works through the in-page tailnet too. */
async function eventLoop() {
  for (;;) {
    try {
      const res = await apiFetch("/events", { headers: { accept: "text/event-stream" } });
      if (!res.ok || !res.body) throw new Error(`events: ${res.status}`);
      const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += value;
        let idx;
        while ((idx = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const data = block
            .split("\n")
            .filter((l) => l.startsWith("data:"))
            .map((l) => l.slice(5).trimStart())
            .join("\n");
          if (!data) continue;
          try {
            const ev = JSON.parse(data);
            if (ev.type === "queue") get().setQueue(ev.queue);
            if (ev.type === "import") set((s) => ({ importTick: s.importTick + 1 }));
            if (ev.type === "profile") loadProfile();
          } catch {
            /* ignore */
          }
        }
      }
    } catch {
      /* reconnect below */
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
}

let started = false;

export async function initPlayer() {
  if (started) return;
  started = true;
  try {
    const q = await api.queue.get();
    // Don't autoplay on load; just show where we left off.
    const it = q.items[q.index];
    if (it) {
      loadedUid = it.uid;
      beginSession(it.track);
      setSrc(it.track, false);
      set({ buffering: false });
    }
    get().setQueue(q);
  } catch {
    /* unauthorized or offline; UI handles it */
  }
  eventLoop();
  // Re-sync whenever the app comes back to the foreground (streams may have been suspended).
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") api.queue.get().then(get().setQueue).catch(() => {});
  });
}
