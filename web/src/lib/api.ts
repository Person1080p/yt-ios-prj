import { apiFetch } from "./transport";

export type Track = {
  videoId: string;
  title: string;
  artist: string;
  album?: string | null;
  duration?: number | null;
  thumbnail?: string | null;
};

export type QueueItem = { uid: string; track: Track; auto: boolean };
export type Queue = { items: QueueItem[]; index: number; autoplay: boolean; version: number; profile?: string };
export type InsertAt = "next" | "end" | "now";

export type HomeItem = {
  kind: "song" | "video" | "playlist" | "album" | "artist";
  title: string;
  subtitle: string;
  thumbnail?: string | null;
  videoId?: string | null;
  playlistId?: string | null;
  browseId?: string | null;
  track?: Track | null;
};
export type Shelf = { title: string; items: HomeItem[] };

export type PlaylistSummary = { id: number; name: string; count: number; updatedAt: number; thumbnail?: string | null };
export type Playlist = { id: number; name: string; tracks: Track[] };

export type LikedEntry = {
  id: number;
  provider: string;
  title: string;
  artist: string;
  album?: string | null;
  status: "matched" | "unmatched" | "error" | "manual";
  track?: Track | null;
};

export type ImportJob = {
  id: number;
  provider: string;
  status: "running" | "done" | "failed";
  total: number;
  done: number;
  matched: number;
  error?: string | null;
  startedAt: number;
  finishedAt?: number | null;
};

export type HistoryEntry = { playedAt: number; source: string; scrobbled: boolean; track: Track };

export type ProfileInfo = { active: "main" | "fresh"; freshPlays: number; freshStartedAt?: number | null };

export type Prefs = {
  preferPlex: boolean;
  scrobble: boolean;
  reportYoutube: boolean;
  loveOnLastfm: boolean;
  syncLastfmLoves: boolean;
};

export type LikedState = { inLibrary: boolean; lastfmLoved?: boolean | null; liked: boolean };

export type TailscaleInfo = {
  mode: "embedded" | "host" | "none" | "";
  online: boolean;
  dnsName?: string | null;
  ips: string[];
  url?: string | null;
  hint?: string | null;
  state?: string | null;
  authUrl?: string | null;
};

export type Status = {
  ytdlp: { path?: string | null; version?: string | null };
  ytmusic: {
    authenticated: boolean;
    activeNow: boolean;
    source?: string | null;
    account?: string | null;
    syncedAt?: number | null;
  };
  plex: { connected: boolean; url?: string | null; loggedIn: boolean };
  lastfm: { configured: boolean; keysFromEnv: boolean; connected: boolean; username?: string | null };
  spotify: { configured: boolean; connected: boolean };
  deezer: { userId?: string | null };
  prefs: Prefs;
  tailscale: TailscaleInfo;
  publicUrl: string;
};

export type PlexServer = {
  name: string;
  clientIdentifier: string;
  accessToken: string;
  owned: boolean;
  connections: { uri: string; local: boolean; relay: boolean }[];
};

/** Errors that just mean "no connection yet" — the global banner covers these. */
export const isNotConnected = (e: unknown) => (e as Error)?.name === "NotConnectedError";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function req<T>(
  path: string,
  init?: { method?: string; body?: unknown; raw?: Blob; signal?: AbortSignal },
): Promise<T> {
  const json = init?.body !== undefined;
  const res = await apiFetch(path, {
    method: init?.method ?? (json || init?.raw ? "POST" : "GET"),
    headers: json ? { "content-type": "application/json" } : init?.raw ? { "content-type": "application/octet-stream" } : undefined,
    body: json ? JSON.stringify(init!.body) : init?.raw,
    signal: init?.signal,
  });
  if (res.status === 401) window.dispatchEvent(new Event("ytp:unauthorized"));
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new ApiError(res.status, data.error ?? res.statusText);
  }
  return res.json();
}

const enc = encodeURIComponent;

export const api = {
  home: (refresh = false) => req<{ shelves: Shelf[] }>(`/home${refresh ? "?refresh=1" : ""}`),
  discover: () => req<{ shelves: Shelf[] }>("/discover"),
  search: (q: string, signal?: AbortSignal) => req<Track[]>(`/search?q=${enc(q)}`, { signal }),
  radio: (videoId: string) => req<Track[]>(`/radio/${enc(videoId)}`),
  playlist: (id: string) => req<Track[]>(`/playlist/${enc(id)}`),
  recommendations: (videoId: string) => req<Track[]>(`/recommendations/${enc(videoId)}`),
  source: (videoId: string) => req<{ source: "plex" | "youtube" }>(`/tracks/${enc(videoId)}/source`),
  liked: (videoId: string) => req<LikedState>(`/tracks/${enc(videoId)}/liked`),
  setLiked: (track: Track, liked: boolean) =>
    req<LikedState>(`/tracks/${enc(track.videoId)}/liked`, { method: "PUT", body: { track, liked } }),
  history: () => req<HistoryEntry[]>("/history"),
  playback: (ev: {
    sessionId: string;
    track: Track;
    event: "start" | "progress" | "end";
    position: number;
    duration?: number;
    source?: string | null;
  }) => req<{ ok: boolean }>("/playback", { body: ev }),

  queue: {
    get: () => req<Queue>("/queue"),
    add: (tracks: Track[], at: InsertAt = "end") => req<Queue>("/queue/add", { body: { tracks, at } }),
    replace: (tracks: Track[], index = 0) => req<Queue>("/queue/replace", { body: { tracks, index } }),
    radio: (track: Track) => req<Queue>("/queue/radio", { body: { track } }),
    setIndex: (index: number) => req<Queue>("/queue/index", { body: { index } }),
    move: (from: number, to: number) => req<Queue>("/queue/move", { body: { from, to } }),
    remove: (uid: string) => req<Queue>("/queue/remove", { body: { uid } }),
    clear: (all = false) => req<Queue>("/queue/clear", { body: { all } }),
    shuffle: () => req<Queue>("/queue/shuffle", { method: "POST" }),
    autoplay: (enabled: boolean) => req<Queue>("/queue/autoplay", { body: { enabled } }),
  },

  playlists: {
    list: () => req<PlaylistSummary[]>("/playlists"),
    get: (id: number) => req<Playlist>(`/playlists/${id}`),
    create: (name: string, tracks: Track[] = []) => req<Playlist>("/playlists", { body: { name, tracks } }),
    update: (id: number, body: { name?: string; tracks?: Track[]; append?: Track[] }) =>
      req<Playlist>(`/playlists/${id}`, { method: "PUT", body }),
    remove: (id: number) => req<{ ok: boolean }>(`/playlists/${id}`, { method: "DELETE" }),
  },

  library: {
    liked: (params: { provider?: string; status?: string; q?: string } = {}) => {
      const qs = new URLSearchParams(Object.entries(params).filter(([, v]) => v) as [string, string][]);
      return req<LikedEntry[]>(`/library/liked?${qs}`);
    },
    jobs: () => req<ImportJob[]>("/import/jobs"),
    ids: () => req<string[]>("/library/ids"),
    add: (track: Track) => req<{ ok: boolean }>("/library/liked", { body: { track } }),
    remove: (id: number) => req<{ ok: boolean }>(`/library/liked/${id}`, { method: "DELETE" }),
    match: (id: number, track: Track) => req<{ ok: boolean }>(`/library/liked/${id}/match`, { body: { track } }),
    rematch: () => req<{ jobId: number }>("/library/rematch", { method: "POST" }),
    importLastfm: () => req<{ jobId: number }>("/import/lastfm", { method: "POST" }),
    importYtMusic: () => req<{ jobId: number }>("/import/ytmusic", { method: "POST" }),
    importSpotify: () => req<{ jobId: number }>("/import/spotify", { method: "POST" }),
    spotifyLogin: (redirect: string) => req<{ url: string }>(`/import/spotify/login?redirect=${enc(redirect)}`),
    spotifyExchange: (code: string, state: string) => req<{ ok: boolean }>("/import/spotify/exchange", { body: { code, state } }),
    importFile: (file: File, provider: string) =>
      req<{ jobId: number }>(`/import/file?provider=${enc(provider)}&name=${enc(file.name)}`, { raw: file }),
    importDeezer: (userId: string, accessToken?: string) =>
      req<{ jobId: number }>("/import/deezer", { body: { userId, accessToken } }),
    importText: (content: string, provider?: string) =>
      req<{ jobId: number }>("/import/text", { body: { content, provider } }),
  },

  profile: {
    get: () => req<ProfileInfo>("/profile"),
    set: (active: "main" | "fresh") => req<ProfileInfo>("/profile", { method: "PUT", body: { active } }),
    resetFresh: () => req<ProfileInfo>("/profile/fresh/reset", { method: "POST" }),
  },

  status: () => req<Status>("/status"),
  setPrefs: (p: Prefs) => req<Prefs>("/prefs", { method: "PUT", body: p }),
  updateYtdlp: () => req<{ output: string; version?: string }>("/ytdlp/update", { method: "POST" }),
  setYtCookie: (cookie: string) => req<{ ok: boolean; account?: string }>("/ytmusic/cookie", { method: "PUT", body: { cookie } }),
  importYtFromBrowser: (keepInSync: boolean, browser?: string) =>
    req<{ ok: boolean; browser: string; account: string }>("/ytmusic/import-browser", { body: { keepInSync, browser } }),
  syncYt: () => req<{ ok: boolean; synced: boolean }>("/ytmusic/sync", { method: "POST" }),
  deleteYtCookie: () => req<{ ok: boolean }>("/ytmusic/cookie", { method: "DELETE" }),
  setLastfmKeys: (apiKey: string, apiSecret: string) =>
    req<{ ok: boolean }>("/lastfm/keys", { method: "PUT", body: { apiKey, apiSecret } }),
  lastfmLogin: (callback: string) => req<{ url: string }>(`/lastfm/login?callback=${enc(callback)}`),
  lastfmSession: (token: string) => req<{ ok: boolean; username: string }>("/lastfm/session", { body: { token } }),
  lastfmDisconnect: () => req<{ ok: boolean }>("/lastfm", { method: "DELETE" }),
  plexPin: () => req<{ id: number; code: string; authUrl: string }>("/plex/pin", { method: "POST" }),
  plexPinCheck: (id: number) => req<{ authorized: boolean }>(`/plex/pin/${id}`),
  plexServers: () => req<PlexServer[]>("/plex/servers"),
  plexSetServer: (url: string, token: string) => req<{ ok: boolean }>("/plex/server", { method: "PUT", body: { url, token } }),
  plexDisconnect: () => req<{ ok: boolean }>("/plex", { method: "DELETE" }),
  spotifyDisconnect: () => req<{ ok: boolean }>("/spotify", { method: "DELETE" }),
  authCheck: () => req<{ authenticated: boolean; required: boolean }>("/auth/check"),
  login: (token: string) => req<{ ok: boolean }>("/auth/login", { body: { token } }),
};

/** Raw audio response for a track (used when audio can't be loaded by URL, i.e. over the in-page tailnet). */
export function fetchAudio(videoId: string, via?: "youtube" | "pipe", signal?: AbortSignal) {
  return apiFetch(`/stream/${enc(videoId)}${via ? `?via=${via}` : ""}`, { signal });
}

export function streamUrl(videoId: string, via?: "youtube" | "pipe") {
  return `/api/stream/${enc(videoId)}${via ? `?via=${via}` : ""}`;
}

export function fmtTime(sec?: number | null) {
  if (sec == null || !isFinite(sec)) return "–:––";
  const s = Math.max(0, Math.floor(sec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

export function randomId() {
  // crypto.randomUUID is only available in secure contexts (not plain http://100.x.y.z).
  return Array.from({ length: 16 }, () => Math.floor(Math.random() * 36).toString(36)).join("");
}
