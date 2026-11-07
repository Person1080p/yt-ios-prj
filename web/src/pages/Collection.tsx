import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, isNotConnected, type Track } from "../lib/api";
import { enqueue, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { BackIcon, LinkIcon, ListIcon, PlayIcon, QueueIcon, ShuffleIcon } from "../components/Icons";
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
  const toast = useStore((s) => s.toastMsg);
  const [tracks, setTracks] = useState<Track[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Whether this playlist is linked on the Playlists page. Until the check answers (or if it
  // fails) the button offers to link; linking twice just updates the link.
  const [linked, setLinked] = useState(false);
  const isAlbum = id.startsWith("MPRE");
  // Opened from a card the title comes along; from a pasted link it's looked up.
  const given = params.get("title");
  const [info, setInfo] = useState<{ title?: string | null; artist?: string | null; thumbnail?: string | null } | null>(null);
  const title = given ?? info?.title ?? (isAlbum ? "Album" : "Playlist");
  useEffect(() => {
    setInfo(null);
    if (!given) api.playlistInfo(id).then(setInfo).catch(() => {});
  }, [id, given]);

  useEffect(() => {
    setTracks(null);
    api
      .playlist(id)
      .then(setTracks)
      .catch((e) => (isNotConnected(e) ? setTracks([]) : setError(e.message)));
    setLinked(false);
    api.playlists
      .linked()
      .then((all) => setLinked(all.some((p) => p.id === id)))
      .catch(() => {});
  }, [id]);

  const toggleLink = async () => {
    try {
      if (linked) {
        await api.playlists.unlink(id);
        setLinked(false);
        toast("Removed from Playlists");
      } else {
        await api.playlists.link({
          id,
          title,
          subtitle: info?.artist ?? (isAlbum ? tracks?.[0]?.artist ?? null : null),
          thumbnail: info?.thumbnail ?? tracks?.[0]?.thumbnail ?? null,
        });
        setLinked(true);
        toast(`“${title}” is now in Playlists`);
      }
    } catch (e) {
      toast(`Couldn't ${linked ? "remove the link" : "link it"}: ${(e as Error).message}`);
    }
  };

  return (
    <div className="page">
      <button className="btn ghost small" onClick={() => nav(-1)}>
        <BackIcon size={16} /> Back
      </button>
      <div className="collection-head">
        <Cover src={info?.thumbnail ?? tracks?.[0]?.thumbnail} size={120} />
        <div>
          <h1>{title}</h1>
          {isAlbum && tracks?.[0]?.artist && (
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
          <button className="btn ghost" onClick={() => pick(tracks)} title="Copy these tracks into one of your playlists">
            <ListIcon size={16} /> Save a copy
          </button>
          <button
            className={`btn ghost ${linked ? "on" : ""}`}
            onClick={toggleLink}
            aria-pressed={linked}
            title={
              linked
                ? "Remove the link from your Playlists page"
                : "Show this on your Playlists page. It opens from YouTube Music each time, so it stays up to date."
            }
          >
            <LinkIcon size={16} /> {linked ? "Linked in Playlists" : "Link in Playlists"}
          </button>
        </div>
      )}
      {error && <p className="error">{error}</p>}
      {!tracks && !error && <div className="spinner" />}
      {tracks && <TrackList tracks={tracks} onPlay={(i) => playTracks(tracks, i)} />}
    </div>
  );
}
