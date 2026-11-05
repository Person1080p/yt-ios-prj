// Which tracks are in the library (drives filled hearts everywhere), and the heart toggle.

import { create } from "zustand";
import { api, type Track } from "./api";
import { useStore } from "./store";

export const useLibrary = create<{ ids: Set<string>; loaded: boolean }>(() => ({ ids: new Set(), loaded: false }));

export async function loadLibraryIds() {
  try {
    useLibrary.setState({ ids: new Set(await api.library.ids()), loaded: true });
  } catch {
    /* offline */
  }
}

function setLocal(videoId: string, inLibrary: boolean) {
  const ids = new Set(useLibrary.getState().ids);
  if (inLibrary) ids.add(videoId);
  else ids.delete(videoId);
  useLibrary.setState({ ids });
}

/** ♥ toggle: add/remove from the library (and love/unlove on Last.fm when connected). */
export async function setLiked(track: Track, liked: boolean) {
  setLocal(track.videoId, liked); // optimistic
  try {
    const st = await api.setLiked(track, liked);
    setLocal(track.videoId, st.inLibrary);
    useStore.getState().toastMsg(liked ? "Added to your library" : "Removed from your library");
    return st;
  } catch (e) {
    setLocal(track.videoId, !liked);
    useStore.getState().toastMsg((e as Error).message);
    return null;
  }
}
