import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, isNotConnected, type Track } from "../lib/api";
import { enqueue, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { BackIcon, ListIcon, PlayIcon, QueueIcon, ShuffleIcon } from "../components/Icons";
import { Cover, TrackList } from "../components/TrackRow";
import { artistLink } from "../components/Shelf";

function shuffled<T>(a: T[]) {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
}

/** A YouTube Music playlist, mix or album. */
export default function Collection() {
  const { id = "" } = useParams();
  const [params] = useSearchParams();
  const nav = useNavigate();
  const pick = useStore((s) => s.pickPlaylist);
  const [tracks, setTracks] = useState<Track[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const title = params.get("title") ?? "Playlist";

  useEffect(() => {
    setTracks(null);
    api
      .playlist(id)
      .then(setTracks)
      .catch((e) => (isNotConnected(e) ? setTracks([]) : setError(e.message)));
  }, [id]);

  return (
    <div className="page">
      <button className="btn ghost small" onClick={() => nav(-1)}>
        <BackIcon size={16} /> Back
      </button>
      <div className="collection-head">
        <Cover src={tracks?.[0]?.thumbnail} size={120} />
        <div>
          <h1>{title}</h1>
          {id.startsWith("MPRE") && tracks?.[0]?.artist && (
            <button className="link-btn" onClick={() => nav(artistLink(tracks[0].artist))}>
              {tracks[0].artist}
            </button>
          )}
          <p className="muted">{tracks ? `${tracks.length} tracks` : "Loading…"}</p>
        </div>
      </div>
      {tracks && tracks.length > 0 && (
        <div className="row gap wrap">
          <button className="btn" onClick={() => playTracks(tracks)}>
            <PlayIcon size={16} /> Play
          </button>
          <button className="btn ghost" onClick={() => playTracks(shuffled(tracks))}>
            <ShuffleIcon size={16} /> Shuffle
          </button>
          <button className="btn ghost" onClick={() => enqueue(tracks, "end")}>
            <QueueIcon size={16} /> Queue all
          </button>
          <button className="btn ghost" onClick={() => pick(tracks)}>
            <ListIcon size={16} /> Save
          </button>
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {!tracks && !error && <div className="spinner" />}
      {tracks && <TrackList tracks={tracks} onPlay={(i) => playTracks(tracks, i)} />}
    </div>
  );
}
