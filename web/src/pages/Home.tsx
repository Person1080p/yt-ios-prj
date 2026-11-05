import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { api, isNotConnected, type HomeItem, type Shelf } from "../lib/api";
import { playRadio, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { PlayIcon } from "../components/Icons";
import { Cover } from "../components/TrackRow";
import ProfileToggle from "../components/ProfileToggle";
import { useProfile } from "../lib/profile";

function ShelfView({ shelf }: { shelf: Shelf }) {
  const nav = useNavigate();
  const openMenu = useStore((s) => s.openMenu);
  const songs = shelf.items.filter((i) => i.track);
  const allSongs = songs.length === shelf.items.length;

  const open = (item: HomeItem) => {
    if (item.track) {
      // Quick-pick style shelves: play the shelf in order. Single songs elsewhere start a radio.
      if (allSongs && songs.length > 1) {
        playTracks(
          songs.map((s) => s.track!),
          songs.indexOf(item),
        );
      } else {
        playRadio(item.track);
      }
    } else if (item.kind === "artist") {
      nav(`/search?q=${encodeURIComponent(item.title)}`);
    } else {
      const id = item.playlistId ?? item.browseId;
      if (id) nav(`/collection/${encodeURIComponent(id)}?title=${encodeURIComponent(item.title)}`);
    }
  };

  return (
    <section className="shelf">
      <div className="shelf-head">
        <h2>{shelf.title}</h2>
        {allSongs && songs.length > 1 && (
          <button className="btn small ghost" onClick={() => playTracks(songs.map((s) => s.track!))}>
            <PlayIcon size={14} /> Play all
          </button>
        )}
      </div>
      <div className="shelf-scroll">
        {shelf.items.map((item, i) => (
          <div key={i} className="card">
            <button
              className="card-btn"
              onClick={() => open(item)}
              onContextMenu={(e) => {
                if (item.track) {
                  e.preventDefault();
                  openMenu(item.track);
                }
              }}
            >
              <Cover src={item.thumbnail} size={148} round={item.kind === "artist"} />
              <div className="card-title">{item.title}</div>
              <div className="card-sub">{item.subtitle}</div>
            </button>
          </div>
        ))}
      </div>
    </section>
  );
}

export default function Home() {
  const [shelves, setShelves] = useState<Shelf[] | null>(null);
  const [personal, setPersonal] = useState<Shelf[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);

  const [refreshing, setRefreshing] = useState(false);
  const load = (refresh = false) => {
    if (refresh) setRefreshing(true);
    api
      .home(refresh)
      .then((r) => setShelves(r.shelves))
      .catch((e) => (isNotConnected(e) ? setOffline(true) : setError(e.message)))
      .finally(() => setRefreshing(false));
    api.discover().then((r) => setPersonal(r.shelves)).catch(() => {});
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const fresh = useProfile((s) => s.active === "fresh");
  return (
    <div className="page">
      <div className="row between home-head">
        <h1>Listen now</h1>
        <div className="row gap">
          <ProfileToggle compact />
          <button className="btn ghost small" disabled={refreshing} onClick={() => load(true)} title="Get a fresh feed from YouTube Music">
            {refreshing ? "Refreshing…" : "Refresh"}
          </button>
        </div>
      </div>
      {fresh && (
        <p className="fresh-note small">
          <strong>Fresh start</strong> — you're listening as a brand-new user: no history, not signed in to YouTube, nothing
          scrobbled or added to your YouTube history. Recommendations build up from what you play here.
        </p>
      )}
      {personal.map((s) => (
        <ShelfView key={`p-${s.title}`} shelf={s} />
      ))}
      {error && <p className="error">{error}</p>}
      {offline && <p className="muted">Your mixes and recommendations will appear here once you're connected.</p>}
      {!shelves && !error && !offline && <div className="spinner" />}
      {shelves?.map((s, i) => <ShelfView key={`${s.title}-${i}`} shelf={s} />)}
      {shelves && shelves.length < 3 && !fresh && (
        <p className="muted">
          Tip: add your YouTube Music cookie in <Link to="/settings">Settings</Link> for personalised mixes, Quick picks and
          your Supermix.
        </p>
      )}
    </div>
  );
}
