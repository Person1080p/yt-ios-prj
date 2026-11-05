import { useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, isNotConnected, type Track } from "../lib/api";
import { enqueue, playRadio } from "../lib/player";
import { TrackList } from "../components/TrackRow";
import { SearchIcon } from "../components/Icons";

export default function Search() {
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get("q") ?? "");
  const [results, setResults] = useState<Track[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!params.get("q")) input.current?.focus();
  }, [params]);

  useEffect(() => {
    const query = q.trim();
    if (!query) {
      setResults([]);
      return;
    }
    const ctrl = new AbortController();
    const t = setTimeout(() => {
      setLoading(true);
      setError(null);
      setParams({ q: query }, { replace: true });
      api
        .search(query, ctrl.signal)
        .then(setResults)
        .catch((e) => e.name !== "AbortError" && !isNotConnected(e) && setError(e.message))
        .finally(() => setLoading(false));
    }, 350);
    return () => {
      clearTimeout(t);
      ctrl.abort();
    };
  }, [q, setParams]);

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
      {results.length > 0 && (
        <div className="row gap">
          <button className="btn small ghost" onClick={() => enqueue(results, "end")}>
            Add all to queue
          </button>
        </div>
      )}
      {loading && <div className="spinner" />}
      {error && <p className="error">{error}</p>}
      <TrackList tracks={results} onPlay={(i) => playRadio(results[i])} />
      {!loading && q && results.length === 0 && !error && <p className="muted">No results.</p>}
      {!q && <p className="muted">Tap a result to play it with an automatic radio. Use ⋯ to queue it instead.</p>}
    </div>
  );
}
