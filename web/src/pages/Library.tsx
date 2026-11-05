import { useCallback, useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, fmtTime, type ImportJob, type LikedEntry, type Status, type Track } from "../lib/api";
import { enqueue, playRadio, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { CloseIcon, MatchIcon, PlayIcon, QueueIcon, ShuffleIcon } from "../components/Icons";
import { Sheet } from "../components/Sheets";
import { loadLibraryIds } from "../lib/library";
import { Cover, TrackRow } from "../components/TrackRow";

const PROVIDERS: Record<string, string> = {
  local: "Added here",
  ytmusic: "YouTube Music",
  lastfm: "Last.fm",
  spotify: "Spotify",
  deezer: "Deezer",
  demus: "Demus",
  file: "File",
  rematch: "Retry unmatched",
};

function JobRow({ job }: { job: ImportJob }) {
  const pct = job.total ? Math.round((job.done / job.total) * 100) : 0;
  return (
    <div className="job">
      <div className="row between">
        <strong>{PROVIDERS[job.provider] ?? job.provider}</strong>
        <span className={`muted small status-${job.status}`}>
          {job.status === "running" ? `${job.done}/${job.total || "?"}` : job.status} · {job.matched} matched
        </span>
      </div>
      {job.status === "running" && (
        <div className="progress">
          <div style={{ width: `${pct}%` }} />
        </div>
      )}
      {job.error && <div className="error small">{job.error}</div>}
    </div>
  );
}

function ImportPanel({ status, onStarted }: { status: Status | null; onStarted: () => void }) {
  const toast = useStore((s) => s.toastMsg);
  const [deezerId, setDeezerId] = useState("");
  const [deezerToken, setDeezerToken] = useState("");
  const [text, setText] = useState("");

  useEffect(() => {
    if (status?.deezer.userId) setDeezerId(status.deezer.userId);
  }, [status]);

  const run = async (p: Promise<unknown>, label: string) => {
    try {
      await p;
      toast(`${label} import started`);
      onStarted();
    } catch (e) {
      toast((e as Error).message);
    }
  };

  return (
    <div className="panel">
      <h2>Import liked tracks</h2>
      <p className="muted small">
        Tracks from other services are matched to YouTube Music automatically. Plex copies are used for playback when
        available.
      </p>

      <div className="import-row">
        <div>
          <strong>YouTube Music</strong>
          <div className="muted small">{status?.ytmusic.authenticated ? "Cookie configured" : "Needs cookie in Settings"}</div>
        </div>
        <button className="btn" disabled={!status?.ytmusic.authenticated} onClick={() => run(api.library.importYtMusic(), "YouTube Music")}>
          Import
        </button>
      </div>

      <div className="import-row">
        <div>
          <strong>Spotify</strong>
          <div className="muted small">
            {!status?.spotify.configured
              ? "Set SPOTIFY_CLIENT_ID on the server"
              : status.spotify.connected
                ? "Connected"
                : `Not connected · redirect URI: ${location.origin}/oauth/spotify`}
          </div>
        </div>
        <div className="row gap">
          {status?.spotify.configured && !status.spotify.connected && (
            <button
              className="btn ghost"
              onClick={async () => {
                try {
                  window.location.href = (await api.library.spotifyLogin(`${location.origin}/oauth/spotify`)).url;
                } catch (e) {
                  toast((e as Error).message);
                }
              }}
            >
              Connect
            </button>
          )}
          <button className="btn" disabled={!status?.spotify.connected} onClick={() => run(api.library.importSpotify(), "Spotify")}>
            Import
          </button>
        </div>
      </div>

      <div className="import-row column">
        <div className="row between">
          <div>
            <strong>Last.fm loved tracks</strong>
            <div className="muted small">
              {status?.lastfm.connected ? `Connected as ${status.lastfm.username}` : "Connect Last.fm in Settings first"}
            </div>
          </div>
          <button className="btn" disabled={!status?.lastfm.connected} onClick={() => run(api.library.importLastfm(), "Last.fm")}>
            Import
          </button>
        </div>
        {status?.lastfm.connected && (
          <label className="switch">
            <input
              type="checkbox"
              checked={!!status.prefs.syncLastfmLoves}
              onChange={(e) => api.setPrefs({ ...status.prefs, syncLastfmLoves: e.target.checked }).then(onStarted)}
            />
            <span>Keep in sync daily (loves are added, un-loves removed)</span>
          </label>
        )}
      </div>

      <div className="import-row column">
        <div>
          <strong>Deezer</strong>
          <div className="muted small">Profile ID or URL (profile must be public, or supply an access token)</div>
        </div>
        <div className="row gap wrap">
          <input className="input grow" placeholder="e.g. 123456789" value={deezerId} onChange={(e) => setDeezerId(e.target.value)} />
          <input className="input grow" placeholder="access token (optional)" value={deezerToken} onChange={(e) => setDeezerToken(e.target.value)} />
          <button className="btn" disabled={!deezerId.trim()} onClick={() => run(api.library.importDeezer(deezerId, deezerToken || undefined), "Deezer")}>
            Import
          </button>
        </div>
      </div>

      <div className="import-row">
        <div>
          <strong>Demus</strong>
          <div className="muted small">In Demus, export/share your library or a playlist, save the file, and pick it here.</div>
        </div>
        <label className="btn">
          Choose export…
          <input
            type="file"
            hidden
            onChange={(e) => {
              const f = e.target.files?.[0];
              e.target.value = "";
              if (f) run(api.library.importFile(f, "demus"), "Demus");
            }}
          />
        </label>
      </div>

      <div className="import-row column">
        <div>
          <strong>Other files / paste</strong>
          <div className="muted small">
            CSV (Exportify, TuneMyMusic, Soundiiz…), JSON, M3U/M3U8, plist, zip backups, YouTube links — or paste “Artist -
            Title” lines.
          </div>
        </div>
        <textarea className="input" rows={4} placeholder="Daft Punk - Get Lucky" value={text} onChange={(e) => setText(e.target.value)} />
        <div className="row gap wrap">
          <label className="btn ghost">
            Upload file…
            <input
              type="file"
              hidden
              onChange={(e) => {
                const f = e.target.files?.[0];
                e.target.value = "";
                if (f) run(api.library.importFile(f, "file"), f.name);
              }}
            />
          </label>
          <button
            className="btn"
            disabled={!text.trim()}
            onClick={() => run(api.library.importText(text), "Pasted list").then(() => setText(""))}
          >
            Import pasted
          </button>
        </div>
      </div>
    </div>
  );
}

/** Pick which YouTube track a library entry should play. */
function MatchSheet({ entry, onClose, onDone }: { entry: LikedEntry; onClose: () => void; onDone: () => void }) {
  const toast = useStore((s) => s.toastMsg);
  const [q, setQ] = useState(`${entry.artist} ${entry.title}`);
  const [results, setResults] = useState<Track[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const search = useCallback(async (query: string) => {
    setResults(null);
    setError(null);
    try {
      setResults(await api.search(query));
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);
  useEffect(() => {
    search(`${entry.artist} ${entry.title}`);
  }, [entry, search]);

  const use = async (t: Track) => {
    try {
      await api.library.match(entry.id, t);
      toast(`Matched to “${t.title}”`);
      loadLibraryIds();
      onDone();
    } catch (e) {
      toast((e as Error).message);
    }
  };

  return (
    <Sheet onClose={onClose}>
      <h3 className="sheet-title">{entry.track ? "Change match" : "Find match"}</h3>
      <p className="small muted" style={{ margin: "0 8px 10px" }}>
        For <strong>{entry.title}</strong> by {entry.artist}
        {entry.album ? ` · ${entry.album}` : ""} ({PROVIDERS[entry.provider] ?? entry.provider})
      </p>
      <form
        className="row gap"
        onSubmit={(e) => {
          e.preventDefault();
          search(q);
        }}
      >
        <input className="input" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn" type="submit">
          Search
        </button>
      </form>
      {error && <p className="error small">{error}</p>}
      {!results && !error && <div className="spinner" />}
      <div className="sheet-list">
        {results?.map((t) => (
          <div key={t.videoId} className={`match-row ${entry.track?.videoId === t.videoId ? "current" : ""}`}>
            <button className="track-main" onClick={() => playRadio(t)} title="Preview">
              <Cover src={t.thumbnail} size={44} />
              <div className="track-text">
                <div className="track-title">{t.title}</div>
                <div className="track-sub">
                  {t.artist}
                  {t.album ? ` · ${t.album}` : ""} · {fmtTime(t.duration)}
                </div>
              </div>
            </button>
            {entry.track?.videoId === t.videoId ? (
              <span className="small muted">current</span>
            ) : (
              <button className="btn small" onClick={() => use(t)}>
                Use this
              </button>
            )}
          </div>
        ))}
        {results?.length === 0 && <p className="muted small">No results — try a different search.</p>}
      </div>
    </Sheet>
  );
}

export default function Library() {
  const [params] = useSearchParams();
  const tick = useStore((s) => s.importTick);
  const toast = useStore((s) => s.toastMsg);
  const [liked, setLikedEntries] = useState<LikedEntry[]>([]);
  const [jobs, setJobs] = useState<ImportJob[]>([]);
  const [status, setStatus] = useState<Status | null>(null);
  const [provider, setProvider] = useState("");
  const [onlyUnmatched, setOnlyUnmatched] = useState(false);
  const [q, setQ] = useState("");
  const [showImport, setShowImport] = useState(false);
  const [matching, setMatching] = useState<LikedEntry | null>(null);

  const load = useCallback(() => {
    api.library
      .liked({ provider, q, status: onlyUnmatched ? "unmatched" : undefined })
      .then(setLikedEntries)
      .catch(() => {});
    api.library.jobs().then(setJobs).catch(() => {});
  }, [provider, q, onlyUnmatched]);

  const loadStatus = useCallback(() => api.status().then(setStatus).catch(() => {}), []);

  useEffect(() => {
    const t = setTimeout(load, 200);
    return () => clearTimeout(t);
  }, [load, tick]);

  useEffect(() => {
    loadStatus();
    if (params.get("import")) setShowImport(true);
  }, [params, loadStatus]);

  const running = jobs.some((j) => j.status === "running");
  useEffect(() => {
    if (!running) return;
    const t = setInterval(load, 3000);
    return () => clearInterval(t);
  }, [running, load]);
  useEffect(() => {
    if (!running) loadLibraryIds();
  }, [running]);

  const playable: Track[] = liked.filter((l) => l.track).map((l) => l.track!);
  const unmatched = liked.filter((l) => l.status === "unmatched" || l.status === "error").length;

  const remove = async (l: LikedEntry) => {
    await api.library.remove(l.id);
    setLikedEntries((cur) => cur.filter((x) => x.id !== l.id));
    loadLibraryIds();
    toast(`Removed “${l.title}” from your library`);
  };

  return (
    <div className="page">
      <div className="row between">
        <h1>Library</h1>
        <button className="btn ghost small" onClick={() => setShowImport((s) => !s)}>
          {showImport ? "Hide import" : "Import…"}
        </button>
      </div>

      {(showImport || liked.length === 0) && (
        <ImportPanel
          status={status}
          onStarted={() => {
            load();
            loadStatus();
          }}
        />
      )}
      {jobs.filter((j) => j.status === "running" || Date.now() / 1000 - (j.finishedAt ?? 0) < 600).map((j) => (
        <JobRow key={j.id} job={j} />
      ))}

      <div className="row gap wrap">
        <input className="input grow" type="search" placeholder="Filter liked tracks" value={q} onChange={(e) => setQ(e.target.value)} />
        <select className="input" value={provider} onChange={(e) => setProvider(e.target.value)}>
          <option value="">All sources</option>
          {Object.entries(PROVIDERS)
            .filter(([k]) => k !== "rematch")
            .map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
        </select>
        <label className="switch">
          <input type="checkbox" checked={onlyUnmatched} onChange={(e) => setOnlyUnmatched(e.target.checked)} />
          <span>Unmatched only</span>
        </label>
      </div>

      <div className="row gap wrap">
        {playable.length > 0 && (
          <>
            <button className="btn" onClick={() => playTracks(playable)}>
              <PlayIcon size={16} /> Play {playable.length}
            </button>
            <button className="btn ghost" onClick={() => playTracks([...playable].sort(() => Math.random() - 0.5))}>
              <ShuffleIcon size={16} /> Shuffle
            </button>
            <button className="btn ghost" onClick={() => enqueue(playable, "end")}>
              <QueueIcon size={16} /> Queue all
            </button>
          </>
        )}
        {unmatched > 0 && (
          <button
            className="btn ghost"
            disabled={running}
            title="Search again for tracks that didn't match (including ones whose lookup failed)"
            onClick={() =>
              api.library
                .rematch()
                .then(() => {
                  toast(`Retrying ${unmatched} unmatched tracks`);
                  load();
                })
                .catch((e) => toast(e.message))
            }
          >
            <MatchIcon size={16} /> Retry unmatched ({unmatched})
          </button>
        )}
      </div>

      <div className="track-list">
        {liked.map((l) =>
          l.track ? (
            <TrackRow
              key={l.id}
              track={l.track}
              onPlay={() => playTracks(playable, playable.indexOf(l.track!))}
              trailing={
                <>
                  <span className="provider-tag" title={l.status === "manual" ? "Matched by you" : undefined}>
                    {PROVIDERS[l.provider] ?? l.provider}
                    {l.status === "manual" ? " · ✓" : ""}
                  </span>
                  <button className="icon-btn" aria-label="Change match" title="Change match" onClick={() => setMatching(l)}>
                    <MatchIcon size={18} />
                  </button>
                </>
              }
            />
          ) : (
            <div key={l.id} className="track-row unmatched">
              <div className="track-main">
                <div className="track-text">
                  <div className="track-title">{l.title}</div>
                  <div className="track-sub">
                    {l.artist} ·{" "}
                    <span className="error">{l.status === "error" ? "lookup failed — retry" : "no match found"}</span>
                  </div>
                </div>
              </div>
              <span className="provider-tag">{PROVIDERS[l.provider] ?? l.provider}</span>
              <button className="btn small ghost" onClick={() => setMatching(l)}>
                Find match
              </button>
              <button className="icon-btn" aria-label="Remove from library" title="Remove from library" onClick={() => remove(l)}>
                <CloseIcon size={18} />
              </button>
            </div>
          ),
        )}
      </div>

      {matching && (
        <MatchSheet
          entry={matching}
          onClose={() => setMatching(null)}
          onDone={() => {
            setMatching(null);
            load();
          }}
        />
      )}
    </div>
  );
}
