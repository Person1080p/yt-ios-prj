import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { api, isNotConnected, type HomeItem, type SearchFilter, type SearchResults, type Track } from "../lib/api";
import { linkPath, parseYouTubeLink } from "../lib/links";
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
function TopResult({ item, label: heading }: { item: HomeItem; label?: string }) {
  const nav = useNavigate();
  const link = itemLink(item);
  const kind = { artist: "Artist", album: "Album", playlist: "Playlist", song: "Song", video: "Video" }[item.kind];
  const label = heading ?? `Top result · ${kind}`;
  return (
    <button
      className="top-result"
      onClick={() => (item.track ? playRadio(item.track) : link && nav(link))}
    >
      <Cover src={item.thumbnail} size={96} round={item.kind === "artist"} />
      <div className="top-result-text">
        <div className="small muted">{label}</div>
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
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get("q") ?? "");
  const [tab, setTab] = useState<Tab>((params.get("tab") as Tab) || "all");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  // A YouTube link in the box: playlists, albums and channels open directly; a video is shown
  // as the one result (playing needs a tap, which iOS requires anyway).
  const link = useMemo(() => parseYouTubeLink(q), [q]);
  const [linkTrack, setLinkTrack] = useState<Track | null>(null);

  useEffect(() => {
    if (!params.get("q")) input.current?.focus();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    setLinkTrack(null);
    if (!link) return;
    setResults(null);
    if (link.kind !== "video") {
      // A short wait, so a link being typed out isn't opened half-way. Not written to the URL,
      // so going back returns to the search page without re-opening it.
      const t = setTimeout(() => {
        setQ("");
        nav(linkPath(link));
      }, 400);
      return () => clearTimeout(t);
    }
    let alive = true;
    setLoading(true);
    setError(null);
    api
      .track(link.videoId)
      .then((t) => alive && setLinkTrack(t))
      .catch((e) => alive && !isNotConnected(e) && setError(`Couldn't load that video: ${e.message}`))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [link, nav]);

  useEffect(() => {
    const query = q.trim();
    if (!query || link) {
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
  }, [q, tab, setParams, link]);

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
          placeholder="Songs, artists, albums, or a YouTube link"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && linkTrack) playRadio(linkTrack);
          }}
        />
      </div>
      {link?.kind === "video" && (
        <>
          {linkTrack && (
            <TopResult
              item={{
                kind: "song",
                title: linkTrack.title,
                subtitle: linkTrack.artist,
                thumbnail: linkTrack.thumbnail,
                videoId: linkTrack.videoId,
                track: linkTrack,
              }}
              label="From the link"
            />
          )}
          {link.list && (
            <button className="btn ghost" onClick={() => nav(linkPath({ kind: "playlist", id: link.list! }))}>
              Open the playlist this link is from
            </button>
          )}
        </>
      )}
      {q.trim() && !link && (
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
      {r?.fallback && (
        <p className="notice small" title={r.fallback}>
          YouTube search isn't working right now, so these are songs from your Plex library and the server's audio cache.
        </p>
      )}

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

      {!loading && empty && !error && <p className="muted">{r?.fallback ? "Nothing matching in Plex or the audio cache." : "No results."}</p>}
      {!q && (
        <p className="muted">
          Find songs, artists and albums. Tapping a song plays it with an automatic radio; use ⋯ to queue it instead.
        </p>
      )}
    </div>
  );
}
