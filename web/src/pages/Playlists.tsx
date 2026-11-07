import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api, type LinkedPlaylist, type Playlist, type PlaylistSummary } from "../lib/api";
import { enqueue, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { BackIcon, CloseIcon, PlayIcon, PlusIcon, QueueIcon, ShuffleIcon, TrashIcon } from "../components/Icons";
import { Cover, TrackRow } from "../components/TrackRow";

export function PlaylistsPage() {
  const [lists, setLists] = useState<PlaylistSummary[] | null>(null);
  const [linked, setLinked] = useState<LinkedPlaylist[]>([]);
  const [name, setName] = useState("");
  const queue = useStore((s) => s.queue);
  const toast = useStore((s) => s.toastMsg);
  const load = () => {
    api.playlists.list().then(setLists).catch((e) => toast(e.message));
    api.playlists.linked().then(setLinked).catch(() => {});
  };
  const unlink = async (p: LinkedPlaylist) => {
    await api.playlists.unlink(p.id);
    setLinked((cur) => cur.filter((x) => x.id !== p.id));
    toast(`Removed “${p.title}” from Playlists`);
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const create = async (fromQueue: boolean) => {
    const n = name.trim() || (fromQueue ? `Queue ${new Date().toLocaleDateString()}` : "");
    if (!n) return;
    await api.playlists.create(n, fromQueue ? (queue?.items ?? []).map((i) => i.track) : []);
    setName("");
    load();
  };

  return (
    <div className="page">
      <h1>Playlists</h1>
      <form
        className="row gap wrap"
        onSubmit={(e) => {
          e.preventDefault();
          create(false);
        }}
      >
        <input className="input grow" placeholder="New playlist" value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn" type="submit" disabled={!name.trim()}>
          <PlusIcon size={16} /> Create
        </button>
        <button className="btn ghost" type="button" onClick={() => create(true)} disabled={!queue?.items.length}>
          Save current queue
        </button>
      </form>
      {!lists && <div className="spinner" />}
      <div className="grid">
        {lists?.map((p) => (
          <Link key={p.id} to={`/playlists/${p.id}`} className="card-btn">
            <Cover src={p.thumbnail} size={148} />
            <div className="card-title">{p.name}</div>
            <div className="card-sub">{p.count} tracks</div>
          </Link>
        ))}
      </div>
      {lists?.length === 0 && <p className="muted">No playlists yet. Use ⋯ → “Add to playlist” on any track.</p>}

      {linked.length > 0 && (
        <section className="shelf">
          <div className="shelf-head">
            <h2>From YouTube Music</h2>
          </div>
          <p className="small muted">Linked playlists and albums open from YouTube Music, so they stay up to date.</p>
          <div className="grid">
            {linked.map((p) => (
              <div key={p.id} className="linked-card">
                <Link to={`/collection/${encodeURIComponent(p.id)}?title=${encodeURIComponent(p.title)}`} className="card-btn">
                  <Cover src={p.thumbnail} size={148} />
                  <div className="card-title">{p.title}</div>
                  <div className="card-sub">{p.subtitle || (p.id.startsWith("MPRE") ? "Album" : "Playlist")}</div>
                </Link>
                <button className="icon-btn linked-remove" aria-label={`Remove ${p.title} from Playlists`} title="Remove from Playlists" onClick={() => unlink(p)}>
                  <CloseIcon size={16} />
                </button>
              </div>
            ))}
          </div>
        </section>
      )}
      {lists && linked.length === 0 && (
        <p className="small muted">Open a playlist or album from Home or Search and use “Link in Playlists” to keep it here.</p>
      )}
    </div>
  );
}

export function PlaylistDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const toast = useStore((s) => s.toastMsg);
  const [pl, setPl] = useState<Playlist | null>(null);

  useEffect(() => {
    api.playlists.get(Number(id)).then(setPl).catch((e) => toast(e.message));
  }, [id, toast]);

  if (!pl) return <div className="page"><div className="spinner" /></div>;

  const save = async (tracks = pl.tracks, name?: string) => {
    setPl(await api.playlists.update(pl.id, { tracks, name }));
  };
  const move = (i: number, d: number) => {
    const j = i + d;
    if (j < 0 || j >= pl.tracks.length) return;
    const t = [...pl.tracks];
    [t[i], t[j]] = [t[j], t[i]];
    save(t);
  };

  return (
    <div className="page">
      <button className="btn ghost small" onClick={() => nav("/playlists")}>
        <BackIcon size={16} /> Playlists
      </button>
      <div className="collection-head">
        <Cover src={pl.tracks[0]?.thumbnail} size={120} />
        <div>
          <h1
            contentEditable
            suppressContentEditableWarning
            onBlur={(e) => {
              const n = e.currentTarget.textContent?.trim();
              if (n && n !== pl.name) save(undefined, n);
            }}
          >
            {pl.name}
          </h1>
          <p className="muted">{pl.tracks.length} tracks · tap the name to rename</p>
        </div>
      </div>
      <div className="row gap wrap">
        <button className="btn" onClick={() => playTracks(pl.tracks)} disabled={!pl.tracks.length}>
          <PlayIcon size={16} /> Play
        </button>
        <button
          className="btn ghost"
          onClick={() => playTracks([...pl.tracks].sort(() => Math.random() - 0.5))}
          disabled={!pl.tracks.length}
        >
          <ShuffleIcon size={16} /> Shuffle
        </button>
        <button className="btn ghost" onClick={() => enqueue(pl.tracks, "end")} disabled={!pl.tracks.length}>
          <QueueIcon size={16} /> Queue all
        </button>
        <button
          className="btn ghost danger"
          onClick={async () => {
            if (!confirm(`Delete “${pl.name}”?`)) return;
            await api.playlists.remove(pl.id);
            nav("/playlists");
          }}
        >
          <TrashIcon size={16} /> Delete
        </button>
      </div>
      <div className="track-list">
        {pl.tracks.map((t, i) => (
          <TrackRow
            key={`${t.videoId}-${i}`}
            track={t}
            onPlay={() => playTracks(pl.tracks, i)}
            leading={
              <span className="reorder">
                <button className="icon-btn tiny" onClick={() => move(i, -1)} aria-label="Move up">▲</button>
                <button className="icon-btn tiny" onClick={() => move(i, 1)} aria-label="Move down">▼</button>
              </span>
            }
            trailing={
              <button className="icon-btn" aria-label="Remove" onClick={() => save(pl.tracks.filter((_, j) => j !== i))}>
                <CloseIcon size={18} />
              </button>
            }
          />
        ))}
      </div>
    </div>
  );
}
