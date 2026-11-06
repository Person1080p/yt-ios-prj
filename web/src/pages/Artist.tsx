import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, isNotConnected, type ArtistPage, type ArtistShelf, type GridPage } from "../lib/api";
import { enqueue, playTracks } from "../lib/player";
import { useStore } from "../lib/store";
import { BackIcon, PlayIcon, QueueIcon, RadioIcon, ShuffleIcon } from "../components/Icons";
import { Card, ShelfView } from "../components/Shelf";
import { artUrl, TrackList } from "../components/TrackRow";

function shuffled<T>(a: T[]) {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
}

/** Where a shelf's "See all" goes: the full discography grid, or a playlist. */
function moreLink(shelf: ArtistShelf, artist: string) {
  const m = shelf.more;
  if (!m) return null;
  const title = `${artist} · ${shelf.title}`;
  if (m.browseId.startsWith("VL")) {
    return `/collection/${encodeURIComponent(m.browseId.slice(2))}?title=${encodeURIComponent(title)}`;
  }
  return `/browse/${encodeURIComponent(m.browseId)}?${new URLSearchParams({ ...(m.params ? { params: m.params } : {}), title })}`;
}

/** `/artist?name=…`: find the artist page for a name (from a song), then show it. */
export function ArtistByName() {
  const [params] = useSearchParams();
  const nav = useNavigate();
  const name = params.get("name") ?? "";
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    api
      .artistLookup(name)
      .then((r) =>
        r.id ? nav(`/artist/${encodeURIComponent(r.id)}`, { replace: true }) : setError(`No artist page found for “${name}”.`),
      )
      .catch((e) => setError((e as Error).message));
  }, [name, nav]);
  return (
    <div className="page">
      {error ? (
        <>
          <p className="error">{error}</p>
          <button className="btn ghost" onClick={() => nav(`/search?q=${encodeURIComponent(name)}`, { replace: true })}>
            Search for “{name}”
          </button>
        </>
      ) : (
        <div className="spinner" />
      )}
    </div>
  );
}

export default function Artist() {
  const { id = "" } = useParams();
  const nav = useNavigate();
  const toast = useStore((s) => s.toastMsg);
  const [page, setPage] = useState<ArtistPage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [aboutOpen, setAboutOpen] = useState(false);

  useEffect(() => {
    setPage(null);
    setError(null);
    setAboutOpen(false);
    window.scrollTo(0, 0);
    api
      .artist(id)
      .then(setPage)
      .catch((e) => !isNotConnected(e) && setError((e as Error).message));
  }, [id]);

  /** All their songs (the "See all" playlist), falling back to the top songs. */
  const allSongs = async () => {
    if (!page) return [];
    if (!page.songsPlaylistId) return page.topSongs;
    try {
      const t = await api.playlist(page.songsPlaylistId);
      return t.length ? t : page.topSongs;
    } catch {
      return page.topSongs;
    }
  };
  const radio = async () => {
    if (!page?.radioPlaylistId) return;
    try {
      const t = await api.playlist(page.radioPlaylistId);
      if (t.length) playTracks(t);
      else toast("No radio for this artist");
    } catch (e) {
      toast((e as Error).message);
    }
  };

  return (
    <div className="page artist-page">
      <button className="btn ghost small" onClick={() => nav(-1)}>
        <BackIcon size={16} /> Back
      </button>
      {error && <p className="error">{error}</p>}
      {!page && !error && <div className="spinner" />}
      {page && (
        <>
          <header className="artist-head">
            {page.thumbnail && <img className="artist-photo" src={artUrl(page.thumbnail) ?? undefined} alt="" />}
            <div className="artist-head-text">
              <h1>{page.name}</h1>
              {page.stats && <p className="muted small">{page.stats}</p>}
              <div className="row gap wrap">
                {page.topSongs.length > 0 && (
                  <button className="btn" onClick={() => playTracks(page.topSongs)}>
                    <PlayIcon size={16} /> Play
                  </button>
                )}
                {page.topSongs.length > 0 && (
                  <button className="btn ghost" onClick={async () => playTracks(shuffled(await allSongs()))}>
                    <ShuffleIcon size={16} /> Shuffle
                  </button>
                )}
                {page.radioPlaylistId && (
                  <button className="btn ghost" onClick={radio}>
                    <RadioIcon size={16} /> Radio
                  </button>
                )}
              </div>
            </div>
          </header>

          {page.topSongs.length > 0 && (
            <section className="shelf">
              <div className="shelf-head">
                <h2>Top songs</h2>
                <div className="row gap">
                  <button className="btn small ghost" onClick={() => enqueue(page.topSongs, "end")} title="Add to queue">
                    <QueueIcon size={14} />
                  </button>
                  {page.songsPlaylistId && (
                    <button
                      className="btn small ghost"
                      onClick={() =>
                        nav(`/collection/${encodeURIComponent(page.songsPlaylistId!)}?title=${encodeURIComponent(`${page.name} · Songs`)}`)
                      }
                    >
                      See all
                    </button>
                  )}
                </div>
              </div>
              <TrackList tracks={page.topSongs} onPlay={(i) => playTracks(page.topSongs, i)} />
            </section>
          )}

          {page.shelves.map((s) => (
            <ShelfView key={s.title} shelf={s} more={moreLink(s, page.name)} />
          ))}

          {page.description && (
            <section className="shelf">
              <h2>About</h2>
              <p className={`artist-about ${aboutOpen ? "open" : ""}`}>{page.description}</p>
              {page.description.length > 280 && (
                <button className="btn small ghost" onClick={() => setAboutOpen(!aboutOpen)}>
                  {aboutOpen ? "Less" : "More"}
                </button>
              )}
            </section>
          )}
        </>
      )}
    </div>
  );
}

/** `/browse/:id?params=…&title=…`: a grid such as an artist's full discography. */
export function BrowseGrid() {
  const { id = "" } = useParams();
  const [params] = useSearchParams();
  const nav = useNavigate();
  const [page, setPage] = useState<GridPage | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setPage(null);
    api
      .browseGrid(id, params.get("params"))
      .then(setPage)
      .catch((e) => !isNotConnected(e) && setError((e as Error).message));
  }, [id, params]);
  return (
    <div className="page">
      <button className="btn ghost small" onClick={() => nav(-1)}>
        <BackIcon size={16} /> Back
      </button>
      <h1>{params.get("title") ?? page?.title ?? ""}</h1>
      {error && <p className="error">{error}</p>}
      {!page && !error && <div className="spinner" />}
      {page && (
        <div className="card-grid">
          {page.items.map((it, i) => (
            <Card key={i} item={it} size={140} />
          ))}
        </div>
      )}
      {page && page.items.length === 0 && <p className="muted">Nothing here.</p>}
    </div>
  );
}
