import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { api, isNotConnected, type HomeItem, type SearchFilter, type SearchResults } from "../lib/api";
import { enqueue, playRadio } from "../lib/player";
import { TrackList, Cover } from "../components/TrackRow";
import { SearchIcon } from "../components/Icons";
import { Card, itemLink, ShelfView } from "../components/Shelf";

type Tab = "all" | SearchFilter;
const TABS: { id: Tab; label: string }[] = [
  { id: "all", label: "All" },
  { id: "songs", label: "Songs" },
  { id: "artists", label: "Artists" },
  { id: "albums", label: "Albums" },
];

/** The best match, shown big: an artist, album or song. */
function TopResult({ item }: { item: HomeItem }) {
  const nav = useNavigate();
  const link = itemLink(item);
  const label = { artist: "Artist", album: "Album", playlist: "Playlist", song: "Song", video: "Video" }[item.kind];
  return (
    <button
      className="top-result"
      onClick={() => (item.track ? playRadio(item.track) : link && nav(link))}
    >
      <Cover src={item.thumbnail} size={96} round={item.kind === "artist"} />
      <div className="top-result-text">
        <div className="small muted">Top result · {label}</div>
        <div className="top-result-title">{item.title}</div>
        {item.subtitle && <div className="small muted">{item.subtitle}</div>}
      </div>
    </button>
  );
}

function Grid({ items }: { items: HomeItem[] }) {
  return (
    <div className="card-grid">
      {items.map((it, i) => (
        <Card key={i} item={it} size={140} />
      ))}
    </div>
  );
}

export default function Search() {
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get("q") ?? "");
  const [tab, setTab] = useState<Tab>((params.get("tab") as Tab) || "all");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!params.get("q")) input.current?.focus();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const query = q.trim();
    if (!query) {
      setResults(null);
      return;
    }
    const ctrl = new AbortController();
    // One request per (debounced) query and tab; the server caches each for hours.
    const t = setTimeout(() => {
      setLoading(true);
      setError(null);
      setParams(tab === "all" ? { q: query } : { q: query, tab }, { replace: true });
      api
        .searchAll(query, tab === "all" ? undefined : tab, ctrl.signal)
        .then(setResults)
        .catch((e) => e.name !== "AbortError" && !isNotConnected(e) && setError(e.message))
        .finally(() => setLoading(false));
    }, 350);
    return () => {
      clearTimeout(t);
      ctrl.abort();
    };
  }, [q, tab, setParams]);

  const r = results;
  const empty =
    r && !r.top && !r.songs.length && !r.artists.length && !r.albums.length && !r.playlists.length && !r.videos.length;
  const artists = r ? [...(r.top?.kind === "artist" && tab === "artists" ? [r.top] : []), ...r.artists] : [];
  const albums = r ? [...(r.top?.kind === "album" && tab === "albums" ? [r.top] : []), ...r.albums] : [];

  return (
    <div className="page">
      <div className="search-box">
        <SearchIcon size={20} />
        <input
          ref={input}
          className="input"
          type="search"
          placeholder="Songs, artists, albums"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
      </div>
      {q.trim() && (
        <div className="tabs search-tabs" role="tablist">
          {TABS.map((t) => (
            <button
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              className={tab === t.id ? "on" : ""}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>
      )}
      {loading && <div className="spinner" />}
      {error && <p className="error">{error}</p>}

      {r && tab === "all" && (
        <>
          {r.top && <TopResult item={r.top} />}
          {r.songs.length > 0 && (
            <section className="shelf">
              <div className="shelf-head">
                <h2>Songs</h2>
                <button className="btn small ghost" onClick={() => setTab("songs")}>
                  See all
                </button>
              </div>
              <TrackList tracks={r.songs.slice(0, 5)} onPlay={(i) => playRadio(r.songs[i])} />
            </section>
          )}
          {r.artists.length > 0 && <ShelfView shelf={{ title: "Artists", items: r.artists }} />}
          {r.albums.length > 0 && <ShelfView shelf={{ title: "Albums", items: r.albums }} />}
          {r.videos.length > 0 && (
            <ShelfView
              shelf={{
                title: "Videos",
                items: r.videos.map((t) => ({ kind: "video", title: t.title, subtitle: t.artist, thumbnail: t.thumbnail, videoId: t.videoId, track: t })),
              }}
            />
          )}
          {r.playlists.length > 0 && <ShelfView shelf={{ title: "Playlists", items: r.playlists }} />}
        </>
      )}

      {r && tab === "songs" && r.songs.length > 0 && (
        <>
          <div className="row gap">
            <button className="btn small ghost" onClick={() => enqueue(r.songs, "end")}>
              Add all to queue
            </button>
          </div>
          <TrackList tracks={r.songs} onPlay={(i) => playRadio(r.songs[i])} />
        </>
      )}
      {r && tab === "artists" && <Grid items={artists} />}
      {r && tab === "albums" && <Grid items={albums} />}

      {!loading && empty && !error && <p className="muted">No results.</p>}
      {!q && (
        <p className="muted">
          Find songs, artists and albums. Tapping a song plays it with an automatic radio; use ⋯ to queue it instead.
        </p>
      )}
    </div>
  );
}
