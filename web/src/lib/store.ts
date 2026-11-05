import { create } from "zustand";
import type { Queue, Track } from "./api";

type State = {
  queue: Queue | null;
  playing: boolean;
  buffering: boolean;
  position: number;
  duration: number;
  source: "plex" | "youtube" | null;
  nowPlayingOpen: boolean;
  menuTrack: Track | null;
  playlistPickerTracks: Track[] | null;
  toast: { id: number; text: string } | null;
  importTick: number;

  setQueue: (q: Queue) => void;
  toastMsg: (text: string) => void;
  openMenu: (t: Track | null) => void;
  pickPlaylist: (tracks: Track[] | null) => void;
  setNowPlaying: (open: boolean) => void;
};

export const useStore = create<State>((set, get) => ({
  queue: null,
  playing: false,
  buffering: false,
  position: 0,
  duration: 0,
  source: null,
  nowPlayingOpen: false,
  menuTrack: null,
  playlistPickerTracks: null,
  toast: null,
  importTick: 0,

  setQueue: (q) => {
    const cur = get().queue;
    // Responses and SSE events can arrive out of order; keep the newest.
    // (The server bumps the version on profile switches too.)
    if (cur && q.version < cur.version) return;
    set({ queue: q });
  },
  toastMsg: (text) => {
    const id = Date.now();
    set({ toast: { id, text } });
    setTimeout(() => {
      if (get().toast?.id === id) set({ toast: null });
    }, 2800);
  },
  openMenu: (t) => set({ menuTrack: t }),
  pickPlaylist: (tracks) => set({ playlistPickerTracks: tracks, menuTrack: null }),
  setNowPlaying: (open) => set({ nowPlayingOpen: open }),
}));

export const currentTrack = (s: State) => (s.queue ? s.queue.items[s.queue.index]?.track ?? null : null);
