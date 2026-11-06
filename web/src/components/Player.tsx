import { useNavigate } from "react-router-dom";
import { useEffect, useRef, useState } from "react";
import { api, fmtTime, type AudioSource, type Track } from "../lib/api";
import { setLiked, useLibrary } from "../lib/library";
import { next, playRadio, previous, seek, toggle } from "../lib/player";
import { currentTrack, useStore } from "../lib/store";
import { ChevronDown, HeartFilledIcon, HeartIcon, MoreIcon, NextIcon, PauseIcon, PlayIcon, PrevIcon, QueueIcon, RadioIcon } from "./Icons";
import { artUrl, Cover } from "./TrackRow";
import { artistLink } from "./Shelf";

/** ♥: filled when the track is in your library or loved on Last.fm; toggles both. */
export function HeartButton({ track, size = 22 }: { track: Track; size?: number }) {
  const inLibrary = useLibrary((s) => s.ids.has(track.videoId));
  const [lastfmLoved, setLastfmLoved] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    setLastfmLoved(null);
    let alive = true;
    api
      .liked(track.videoId)
      .then((st) => alive && setLastfmLoved(st.lastfmLoved ?? null))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [track.videoId]);
  const liked = inLibrary || lastfmLoved === true;
  return (
    <button
      className={`icon-btn heart ${liked ? "on" : ""}`}
      aria-label={liked ? "Remove from library" : "Add to library"}
      aria-pressed={liked}
      disabled={busy}
      onClick={async () => {
        setBusy(true);
        const st = await setLiked(track, !liked);
        if (st) setLastfmLoved(st.lastfmLoved ?? null);
        setBusy(false);
      }}
    >
      {liked ? <HeartFilledIcon size={size} /> : <HeartIcon size={size} />}
    </button>
  );
}

const SOURCE_NAMES: Record<AudioSource, string> = { plex: "Plex", cache: "Cached", youtube: "YouTube" };

function SourceBadge() {
  const source = useStore((s) => s.source);
  const kbps = useStore((s) => s.streamKbps);
  const budget = useStore((s) => s.qualityBudget);
  if (!source) return null;
  const name = SOURCE_NAMES[source];
  const tip = [source === "cache" ? "MP3 copy the server kept from a recent YouTube play" : "", kbps ? `${kbps} kbps` : ""]
    .filter(Boolean)
    .join(" · ");
  // Show the bitrate when quality is being limited for the connection.
  return (
    <span className={`badge ${source}`} title={tip || undefined}>
      {name}
      {budget != null && kbps ? ` · ${kbps} kbps` : ""}
    </span>
  );
}

/** Loaded parts of the track, drawn in gray behind the progress. */
function BufferedRanges({ duration }: { duration: number }) {
  const buffered = useStore((s) => s.buffered);
  if (!duration) return null;
  return (
    <>
      {buffered.map(([a, b], i) => (
        <div
          key={i}
          className="seek-buffered"
          style={{ left: `${(Math.min(a, duration) / duration) * 100}%`, width: `${((Math.min(b, duration) - Math.min(a, duration)) / duration) * 100}%` }}
        />
      ))}
    </>
  );
}

function Seekbar({ big = false }: { big?: boolean }) {
  const position = useStore((s) => s.position);
  const duration = useStore((s) => s.duration);
  // While dragging, show where you are without seeking on every move (seek on release).
  const [drag, setDrag] = useState<number | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  const shown = drag ?? position;
  const pct = duration ? Math.min(100, (shown / duration) * 100) : 0;
  if (!big) {
    return (
      <div className="mini-progress">
        <BufferedRanges duration={duration} />
        <div className="mini-progress-fill" style={{ width: `${pct}%` }} />
      </div>
    );
  }
  const timeAt = (clientX: number) => {
    const r = ref.current!.getBoundingClientRect();
    return Math.max(0, Math.min(1, (clientX - r.left) / r.width)) * duration;
  };
  return (
    <div className="seek">
      <div
        ref={ref}
        className={`seek-hit ${drag != null ? "dragging" : ""}`}
        role="slider"
        tabIndex={0}
        aria-label="Seek"
        aria-valuemin={0}
        aria-valuemax={Math.round(duration)}
        aria-valuenow={Math.round(shown)}
        aria-valuetext={`${fmtTime(shown)} of ${fmtTime(duration)}`}
        onPointerDown={(e) => {
          if (!duration || e.button !== 0) return;
          e.preventDefault(); // no text selection, no focus jump
          e.currentTarget.setPointerCapture(e.pointerId);
          setDrag(timeAt(e.clientX));
        }}
        onPointerMove={(e) => drag != null && setDrag(timeAt(e.clientX))}
        onPointerUp={(e) => {
          if (drag == null) return;
          seek(timeAt(e.clientX));
          setDrag(null);
        }}
        onPointerCancel={() => setDrag(null)}
        onKeyDown={(e) => {
          const step = { ArrowLeft: -5, ArrowRight: 5, ArrowDown: -10, ArrowUp: 10 }[e.key];
          if (step) seek(position + step);
          else if (e.key === "Home") seek(0);
          else if (e.key === "End") seek(duration);
          else return;
          e.preventDefault();
        }}
      >
        <div className="seek-track">
          <BufferedRanges duration={duration} />
          <div className="seek-fill" style={{ width: `${pct}%` }} />
          <div className="seek-thumb" style={{ left: `${pct}%` }} />
        </div>
      </div>
      <div className="seek-times">
        <span>{fmtTime(shown)}</span>
        <span>{fmtTime(duration)}</span>
      </div>
    </div>
  );
}

export function PlayerBar() {
  const track = useStore(currentTrack);
  const playing = useStore((s) => s.playing);
  const buffering = useStore((s) => s.buffering);
  const open = useStore((s) => s.setNowPlaying);
  if (!track) return null;
  return (
    <div className="player-bar">
      <Seekbar />
      <div className="player-bar-inner">
        <button className="player-bar-info" onClick={() => open(true)}>
          <Cover src={track.thumbnail} size={44} />
          <div className="track-text">
            <div className="track-title">{track.title}</div>
            <div className="track-sub">
              {track.artist} <SourceBadge />
            </div>
          </div>
        </button>
        <div className="player-bar-controls">
          <span className="hide-mobile">
            <HeartButton track={track} size={20} />
          </span>
          <button className="icon-btn hide-mobile" onClick={previous} aria-label="Previous">
            <PrevIcon />
          </button>
          <button className={`icon-btn play ${buffering && playing ? "loading" : ""}`} onClick={toggle} aria-label="Play/pause">
            {playing ? <PauseIcon /> : <PlayIcon />}
          </button>
          <button className="icon-btn" onClick={() => next()} aria-label="Next">
            <NextIcon />
          </button>
        </div>
      </div>
    </div>
  );
}

export function NowPlaying() {
  const isOpen = useStore((s) => s.nowPlayingOpen);
  const setOpen = useStore((s) => s.setNowPlaying);
  const track = useStore(currentTrack);
  const playing = useStore((s) => s.playing);
  const buffering = useStore((s) => s.buffering);
  const openMenu = useStore((s) => s.openMenu);
  const nav = useNavigate();
  if (!isOpen || !track) return null;

  return (
    <div className="now-playing">
      <div
        className="np-bg"
        style={track.thumbnail ? ({ "--np-art": `url("${artUrl(track.thumbnail)}")` } as React.CSSProperties) : undefined}
      />
      <header className="np-header">
        <button className="icon-btn" onClick={() => setOpen(false)} aria-label="Close">
          <ChevronDown size={28} />
        </button>
        <span className="np-label">Now playing</span>
        <button className="icon-btn" onClick={() => openMenu(track)} aria-label="More">
          <MoreIcon />
        </button>
      </header>
      <div className="np-art">
        <Cover src={track.thumbnail} size={340} />
      </div>
      <div className="np-meta">
        <h2>{track.title}</h2>
        <p>
          <button
            className="link-btn"
            onClick={() => {
              setOpen(false);
              nav(artistLink(track.artist));
            }}
            title="Go to artist"
          >
            {track.artist}
          </button>
          {track.album ? ` · ${track.album}` : ""}
        </p>
        <SourceBadge />
      </div>
      <Seekbar big />
      <div className="np-controls">
        <HeartButton track={track} />
        <button className="icon-btn" onClick={previous} aria-label="Previous">
          <PrevIcon size={30} />
        </button>
        <button className={`icon-btn play big ${buffering && playing ? "loading" : ""}`} onClick={toggle} aria-label="Play/pause">
          {playing ? <PauseIcon size={34} /> : <PlayIcon size={34} />}
        </button>
        <button className="icon-btn" onClick={() => next()} aria-label="Next">
          <NextIcon size={30} />
        </button>
        <button
          className="icon-btn"
          aria-label="Queue"
          onClick={() => {
            setOpen(false);
            nav("/queue");
          }}
        >
          <QueueIcon />
        </button>
      </div>
      <button className="btn ghost np-radio" onClick={() => playRadio(track)}>
        <RadioIcon size={18} /> Start radio from this song
      </button>
    </div>
  );
}
