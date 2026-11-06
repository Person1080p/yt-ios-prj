import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api, isNotConnected, type Shelf } from "../lib/api";
import { ShelfView } from "../components/Shelf";
import ProfileToggle from "../components/ProfileToggle";
import { useProfile } from "../lib/profile";

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
