import { switchProfile, useProfile } from "../lib/profile";

/** The "Fresh start" switch: listen as a brand-new user with no history. */
export default function ProfileToggle({ compact = false }: { compact?: boolean }) {
  const active = useProfile((s) => s.active);
  const switching = useProfile((s) => s.switching);
  const fresh = active === "fresh";
  return (
    <label
      className={`switch profile-toggle ${fresh ? "on" : ""} ${compact ? "compact" : ""}`}
      title="Listen as a brand-new user: no listening history, not signed in to YouTube, no scrobbling"
    >
      <input type="checkbox" checked={fresh} disabled={switching} onChange={(e) => switchProfile(e.target.checked ? "fresh" : "main")} />
      <span>Fresh start</span>
    </label>
  );
}
