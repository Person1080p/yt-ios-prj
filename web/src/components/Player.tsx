import { useNavigate } from "react-router-dom";
import { useEffect, useState } from "react";
import { api, fmtTime, type Track } from "../lib/api";
import { setLiked, useLibrary } from "../lib/library";
import { next, playRadio, previous, seek, toggle } from "../lib/player";
import { currentTrack, useStore } from "../lib/store";
import { ChevronDown, HeartFilledIcon, HeartIcon, MoreIcon, NextIcon, PauseIcon, PlayIcon, PrevIcon, QueueIcon, RadioIcon } from "./Icons";
import { Cover } from "./TrackRow";

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

function SourceBadge() {
  const source = useStore((s) => s.source);
  if (!source) return null;
  return <span className={`badge ${source}`}>{source === "plex" ? "Plex" : "YouTube"}</span>;
}

function Seekbar({ big = false }: { big?: boolean }) {
  const position = useStore((s) => s.position);
  const duration = useStore((s) => s.duration);
  const pct = duration ? (position / duration) * 100 : 0;
  if (!big) {
    return (
      <div className="mini-progress">
        <div style={{ width: `${pct}%` }} />
      </div>
    );
  }
  return (
    <div className="seek">
      <input
        type="range"
        min={0}
        max={duration || 1}
        step={0.5}
        value={position}
        onChange={(e) => seek(Number(e.target.value))}
        style={{ ["--pct" as string]: `${pct}%` }}
        aria-label="Seek"
      />
      <div className="seek-times">
        <span>{fmtTime(position)}</span>
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
      <div className="np-bg" style={{ backgroundImage: track.thumbnail ? `url(${track.thumbnail})` : undefined }} />
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
          {track.artist}
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
