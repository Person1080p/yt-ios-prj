import type { ReactNode } from "react";
import { fmtTime, type Track } from "../lib/api";
import { currentTrack, useStore } from "../lib/store";
import { MoreIcon } from "./Icons";

export function Cover({ src, size = 48, round = false }: { src?: string | null; size?: number; round?: boolean }) {
  return (
    <div className={`cover ${round ? "round" : ""}`} style={{ width: size, height: size }}>
      {src ? <img src={src} alt="" loading="lazy" referrerPolicy="no-referrer" /> : <span>♪</span>}
    </div>
  );
}

type Props = {
  track: Track;
  onPlay: () => void;
  active?: boolean;
  leading?: ReactNode;
  trailing?: ReactNode;
  dim?: boolean;
};

export function TrackRow({ track, onPlay, active, leading, trailing, dim }: Props) {
  const openMenu = useStore((s) => s.openMenu);
  const playingId = useStore((s) => currentTrack(s)?.videoId);
  const isActive = active ?? playingId === track.videoId;
  return (
    <div className={`track-row ${isActive ? "active" : ""} ${dim ? "dim" : ""}`}>
      {leading}
      <button className="track-main" onClick={onPlay}>
        <Cover src={track.thumbnail} />
        <div className="track-text">
          <div className="track-title">{track.title}</div>
          <div className="track-sub">
            {track.artist}
            {track.album ? ` · ${track.album}` : ""}
          </div>
        </div>
      </button>
      <span className="track-dur">{fmtTime(track.duration)}</span>
      {trailing}
      <button className="icon-btn" aria-label="More" onClick={() => openMenu(track)}>
        <MoreIcon />
      </button>
    </div>
  );
}

export function TrackList({ tracks, onPlay }: { tracks: Track[]; onPlay: (index: number) => void }) {
  return (
    <div className="track-list">
      {tracks.map((t, i) => (
        <TrackRow key={`${t.videoId}-${i}`} track={t} onPlay={() => onPlay(i)} />
      ))}
    </div>
  );
}
