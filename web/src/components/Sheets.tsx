import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, fmtTime, isPlexId, type PlaylistSummary, type PlexChoice, type Track } from "../lib/api";
import { setLiked, useLibrary } from "../lib/library";
import { enqueue, playRadio, reloadSource } from "../lib/player";
import { currentTrack, useStore } from "../lib/store";
import {
  HeartFilledIcon,
  HeartIcon,
  ListIcon,
  MatchIcon,
  PlayIcon,
  PlayNextIcon,
  PlusIcon,
  QueueIcon,
  RadioIcon,
  SearchIcon,
} from "./Icons";
import { Cover } from "./TrackRow";
import { artistLink } from "./Shelf";

export function Sheet({ onClose, children }: { onClose: () => void; children: React.ReactNode }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()}>
        <div className="sheet-grip" />
        {children}
      </div>
    </div>
  );
}

/** Actions for a single track: play now/next, queue, radio, playlist, love. */
export function TrackMenu() {
  const track = useStore((s) => s.menuTrack);
  const close = () => useStore.getState().openMenu(null);
  const pick = useStore((s) => s.pickPlaylist);
  const nav = useNavigate();
  const inLibrary = useLibrary((s) => (track ? s.ids.has(track.videoId) : false));
  const plex = usePlexConnected(!!track);
  if (!track) return null;

  const act = (fn: () => void) => () => {
    fn();
    close();
  };

  return (
    <Sheet onClose={close}>
      <div className="sheet-head">
        <Cover src={track.thumbnail} size={52} />
        <div className="track-text">
          <div className="track-title">{track.title}</div>
          <div className="track-sub">{track.artist}</div>
        </div>
      </div>
      <button className="sheet-item" onClick={act(() => enqueue([track], "now"))}>
        <PlayIcon size={20} /> Play now
      </button>
      <button className="sheet-item" onClick={act(() => enqueue([track], "next"))}>
        <PlayNextIcon size={20} /> Play next
      </button>
      <button className="sheet-item" onClick={act(() => enqueue([track], "end"))}>
        <QueueIcon size={20} /> Add to queue
      </button>
      <button className="sheet-item" onClick={act(() => playRadio(track))}>
        <RadioIcon size={20} /> Start radio
      </button>
      <button className="sheet-item" onClick={() => pick([track])}>
        <ListIcon size={20} /> Add to playlist…
      </button>
      <button className="sheet-item" onClick={act(() => setLiked(track, !inLibrary))}>
        {inLibrary ? <HeartFilledIcon size={20} /> : <HeartIcon size={20} />}
        {inLibrary ? "Remove from library" : "Add to library"}
      </button>
      <button
        className="sheet-item"
        onClick={act(() => {
          useStore.getState().setNowPlaying(false);
          nav(artistLink(track.artist));
        })}
      >
        <SearchIcon size={20} /> Go to {track.artist.split(",")[0]}
      </button>
      {plex && !isPlexId(track.videoId) && (
        <button className="sheet-item" onClick={() => useStore.getState().choosePlexVersion(track)}>
          <MatchIcon size={20} /> Plex version…
        </button>
      )}
    </Sheet>
  );
}

// Whether a Plex server is connected, asked once per session (and again after a failure).
let plexConnected: Promise<boolean> | null = null;
function usePlexConnected(active: boolean) {
  const [on, setOn] = useState(false);
  useEffect(() => {
    if (!active) return;
    plexConnected ??= api.status().then(
      (s) => s.plex.connected,
      () => ((plexConnected = null), false),
    );
    let live = true;
    plexConnected.then((v) => live && setOn(v));
    return () => {
      live = false;
    };
  }, [active]);
  return on;
}

/**
 * Choose which Plex copy a YouTube song plays from: automatic matching, a track you pick (say
 * the studio recording rather than a live one), or not Plex at all.
 */
export function PlexVersionSheet() {
  const track = useStore((s) => s.plexMatchTrack);
  const playingId = useStore((s) => currentTrack(s)?.videoId);
  const toast = useStore((s) => s.toastMsg);
  const close = () => useStore.getState().choosePlexVersion(null);
  const [choice, setChoice] = useState<PlexChoice | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const [results, setResults] = useState<Track[] | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setChoice(null);
    setError(null);
    setResults(null);
    if (!track) return;
    setQ(track.title);
    api.plexMatch(track.videoId).then(setChoice, (e) => setError((e as Error).message));
  }, [track]);
  if (!track) return null;

  // Changes apply straight away: the song switches over in place if it's playing (the queue is
  // left alone), and copies loaded in advance are dropped.
  const run = async (fn: () => Promise<unknown>, msg: string) => {
    setBusy(true);
    try {
      await fn();
      reloadSource(track.videoId);
      toast(msg + (track.videoId === playingId ? " — switching now" : ""));
      close();
    } catch (e) {
      toast((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const use = (t: Track) =>
    run(() => api.plexSetMatch(track.videoId, t.videoId.slice("plex_".length)), `Plays from Plex: ${t.album ?? t.title}`);
  const search = async () => {
    if (!q.trim()) return;
    setResults([]);
    try {
      setResults(await api.plexSearch(q.trim()));
    } catch (e) {
      setError((e as Error).message);
      setResults(null);
    }
  };

  const mode = choice?.mode;
  const listed: { track: Track; live?: boolean }[] = results?.map((t) => ({ track: t })) ?? choice?.candidates ?? [];
  const current = choice?.current;
  return (
    <Sheet onClose={close}>
      <h3 className="sheet-title">Plex version</h3>
      <p className="small muted" style={{ margin: "0 8px 10px" }}>
        For <strong>{track.title}</strong> by {track.artist}
        {track.album ? ` · ${track.album}` : ""} · {fmtTime(track.duration)}
      </p>
      {choice && (
        <div className="tabs" role="tablist" style={{ margin: "0 8px 10px" }}>
          <button
            role="tab"
            aria-selected={mode === "auto"}
            className={mode === "auto" ? "on" : ""}
            disabled={busy || mode === "auto"}
            onClick={() => run(() => api.plexClearMatch(track.videoId, "auto"), "Back to automatic Plex matching")}
            title="Let the app pick the Plex copy"
          >
            Automatic
          </button>
          <button
            role="tab"
            aria-selected={mode === "off"}
            className={mode === "off" ? "on" : ""}
            disabled={busy || mode === "off"}
            onClick={() => run(() => api.plexClearMatch(track.videoId, "off"), "Won't play from Plex")}
            title="Play this song from the audio cache or YouTube instead"
          >
            Don't use Plex
          </button>
        </div>
      )}
      <p className="small muted" style={{ margin: "0 8px 10px" }}>
        {mode === "off"
          ? "This song never plays from Plex. Pick a track below to change that."
          : mode === "picked"
            ? "Plays the Plex track you picked. “Automatic” lets the app choose again."
            : current
            ? "Plays the highlighted Plex track. Pick another to always use that one."
            : choice
              ? "No Plex copy matched automatically. Pick one to use it."
              : ""}
      </p>
      <form
        className="row gap"
        onSubmit={(e) => {
          e.preventDefault();
          search();
        }}
      >
        <input className="input" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search Plex" />
        <button className="btn" type="submit">
          Search
        </button>
      </form>
      {error && <p className="error small">{error}</p>}
      {!choice && !error && <div className="spinner" />}
      <div className="sheet-list">
        {listed.map(({ track: t, live }) => {
          const isCurrent = mode !== "off" && current === t.videoId.slice("plex_".length);
          return (
            <div key={t.videoId} className={`match-row ${isCurrent ? "current" : ""}`}>
              <button
                className="track-main"
                disabled={busy || isCurrent}
                onClick={() => use(t)}
                title={isCurrent ? "Plays from this now" : "Use this version"}
              >
                <Cover src={t.thumbnail} size={44} />
                <div className="track-text">
                  <div className="track-title">{t.title}</div>
                  <div className="track-sub">
                    {t.album ?? t.artist} · {fmtTime(t.duration)}
                    {live ? " · live" : ""}
                  </div>
                </div>
              </button>
              {isCurrent ? (
                <span className="small muted">current</span>
              ) : (
                <button className="btn small" disabled={busy} onClick={() => use(t)}>
                  Use this
                </button>
              )}
            </div>
          );
        })}
        {choice && listed.length === 0 && (
          <p className="muted small">Nothing in Plex for that. Try a shorter search (just the title).</p>
        )}
      </div>
    </Sheet>
  );
}

/** Choose (or create) a saved playlist to add tracks to. */
export function PlaylistPicker() {
  const tracks = useStore((s) => s.playlistPickerTracks);
  const close = () => useStore.getState().pickPlaylist(null);
  const toast = useStore((s) => s.toastMsg);
  const [lists, setLists] = useState<PlaylistSummary[]>([]);
  const [name, setName] = useState("");

  useEffect(() => {
    if (tracks) api.playlists.list().then(setLists).catch(() => {});
  }, [tracks]);
  if (!tracks) return null;

  const add = async (id: number, label: string) => {
    try {
      await api.playlists.update(id, { append: tracks });
      toast(`Added to ${label}`);
      close();
    } catch (e) {
      toast((e as Error).message);
    }
  };
  const create = async () => {
    if (!name.trim()) return;
    try {
      await api.playlists.create(name.trim(), tracks);
      toast(`Created ${name.trim()}`);
      setName("");
      close();
    } catch (e) {
      toast((e as Error).message);
    }
  };

  return (
    <Sheet onClose={close}>
      <h3 className="sheet-title">Add {tracks.length > 1 ? `${tracks.length} tracks` : "to playlist"}</h3>
      <form
        className="row"
        onSubmit={(e) => {
          e.preventDefault();
          create();
        }}
      >
        <input className="input" placeholder="New playlist name" value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn" type="submit" disabled={!name.trim()}>
          <PlusIcon size={18} /> Create
        </button>
      </form>
      <div className="sheet-list">
        {lists.map((p) => (
          <button key={p.id} className="sheet-item" onClick={() => add(p.id, p.name)}>
            <Cover src={p.thumbnail} size={36} /> {p.name} <span className="muted">· {p.count}</span>
          </button>
        ))}
      </div>
    </Sheet>
  );
}

export function Toast() {
  const toast = useStore((s) => s.toast);
  if (!toast) return null;
  return <div className="toast">{toast.text}</div>;
}
