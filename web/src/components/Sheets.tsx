import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, type PlaylistSummary } from "../lib/api";
import { setLiked, useLibrary } from "../lib/library";
import { enqueue, playRadio } from "../lib/player";
import { useStore } from "../lib/store";
import { HeartFilledIcon, HeartIcon, ListIcon, PlayIcon, PlayNextIcon, PlusIcon, QueueIcon, RadioIcon, SearchIcon } from "./Icons";
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
