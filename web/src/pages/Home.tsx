import { useEffect, useRef, useState } from "react";
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
  // Infinite scroll, like YouTube Music's own home page: the token for the next shelves, fetched
  // only when you scroll near the bottom (one YouTube call per page, cached on the server).
  const [next, setNext] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [moreError, setMoreError] = useState(false);
  // Bumped by a refresh so a page still loading for the old feed is dropped.
  const generation = useRef(0);
  const sentinel = useRef<HTMLDivElement>(null);

  const [refreshing, setRefreshing] = useState(false);
  const load = (refresh = false) => {
    const gen = ++generation.current;
    if (refresh) setRefreshing(true);
    setMoreError(false);
    api
      .home(refresh)
      .then((r) => {
        if (gen !== generation.current) return;
        setShelves(r.shelves);
        setNext(r.continuation ?? null);
      })
      .catch((e) => (isNotConnected(e) ? setOffline(true) : setError(e.message)))
      .finally(() => setRefreshing(false));
    api.discover().then((r) => setPersonal(r.shelves)).catch(() => {});
  };
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const loadMore = (token: string) => {
    const gen = generation.current;
    setLoadingMore(true);
    setMoreError(false);
    api
      .homeMore(token)
      .then((r) => {
        if (gen !== generation.current) return;
        setShelves((s) => [...(s ?? []), ...r.shelves]);
        // A page with nothing on it ends the feed rather than asking forever.
        setNext(r.shelves.length > 0 ? r.continuation ?? null : null);
      })
      .catch(() => gen === generation.current && setMoreError(true))
      .finally(() => setLoadingMore(false));
  };

  // Watch the end of the list inside the scrolling pane, starting a little before it shows. The
  // observer is rebuilt after each page, so a page too short to fill the screen loads the next.
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !next || loadingMore || moreError) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect();
          loadMore(next);
        }
      },
      { root: el.closest(".content"), rootMargin: "0px 0px 900px 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [next, loadingMore, moreError]);

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
      <div ref={sentinel} aria-hidden />
      {loadingMore && <div className="spinner" />}
      {moreError && (
        <p className="muted">
          Couldn't load more.{" "}
          <button className="link-btn" onClick={() => next && loadMore(next)}>
            Try again
          </button>
        </p>
      )}
      {shelves && shelves.length < 3 && !fresh && (
        <p className="muted">
          Tip: add your YouTube Music cookie in <Link to="/settings">Settings</Link> for personalised mixes, Quick picks and
          your Supermix.
        </p>
      )}
    </div>
  );
}
