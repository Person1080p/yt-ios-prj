// Listener profile: "main" (you) or "fresh" (a brand-new listener with no history).
// Server-wide, so every device switches together.

import { create } from "zustand";
import { api, type ProfileInfo } from "./api";
import { useStore } from "./store";

export const useProfile = create<ProfileInfo & { loaded: boolean; switching: boolean }>(() => ({
  active: "main",
  freshPlays: 0,
  freshStartedAt: null,
  loaded: false,
  switching: false,
}));

export async function loadProfile() {
  try {
    useProfile.setState({ ...(await api.profile.get()), loaded: true });
  } catch {
    /* offline */
  }
}

export async function switchProfile(active: "main" | "fresh") {
  useProfile.setState({ switching: true });
  try {
    useProfile.setState({ ...(await api.profile.set(active)), loaded: true });
    useStore
      .getState()
      .toastMsg(active === "fresh" ? "Fresh start on — recommendations without your history" : "Back to your profile");
  } catch (e) {
    useStore.getState().toastMsg((e as Error).message);
  } finally {
    useProfile.setState({ switching: false });
  }
}

export async function resetFresh() {
  try {
    useProfile.setState({ ...(await api.profile.resetFresh()), loaded: true });
    useStore.getState().toastMsg("Fresh start profile reset — brand new again");
  } catch (e) {
    useStore.getState().toastMsg((e as Error).message);
  }
}
