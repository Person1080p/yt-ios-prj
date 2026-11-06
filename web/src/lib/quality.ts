// Audio quality vs. the connection between this browser and the ytp server.
//
// The player measures how fast audio actually arrives from the server (see player.ts) and keeps a
// smoothed estimate in kbps. Streams are requested with a bitrate budget of about half of that, so
// there's headroom; the server turns the budget into a YouTube format or a Plex transcode.
// The server's own link to YouTube/Plex isn't part of this: timing starts once audio flows.

import { useStore } from "./store";

export type QualityPref = "auto" | "high" | "normal" | "low";

const KEY = "ytp.quality";
/** Last measured speed, so a reload doesn't start over at full quality on a slow connection. */
const ESTIMATE_KEY = "ytp.netEstimate";
const ESTIMATE_MAX_AGE = 30 * 60 * 1000;
/** Budgets for the fixed choices (kbps; null = no limit). */
const MANUAL: Record<Exclude<QualityPref, "auto">, number | null> = { high: null, normal: 96, low: 48 };
/** Budgets Automatic moves between. Coarse steps, so a preloaded song isn't redone for tiny changes. */
const STEPS = [48, 96, 128, 192, 320];
/** With half the measured speed above this, don't limit at all (lossless Plex files fit). */
const UNLIMITED_ABOVE = 640;

/** Whether this browser plays WebM/Opus; otherwise the server picks AAC formats. */
export const opusOk = (() => {
  try {
    return new Audio().canPlayType('audio/webm; codecs="opus"') !== "";
  } catch {
    return true;
  }
})();

function readPref(): QualityPref {
  try {
    const v = localStorage.getItem(KEY);
    if (v === "auto" || v === "high" || v === "normal" || v === "low") return v;
  } catch {
    /* ignore */
  }
  return "auto";
}

type NetInfo = { saveData?: boolean; effectiveType?: string };

/** Before anything is measured: the browser's own hint, where it gives one (Chrome/Android). */
function initialEstimate(): number | null {
  const c = (navigator as Navigator & { connection?: NetInfo }).connection;
  if (!c) return null;
  if (c.saveData || c.effectiveType === "slow-2g" || c.effectiveType === "2g") return 100;
  if (c.effectiveType === "3g") return 250;
  return null;
}

let pref: QualityPref = readPref();
function savedEstimate(): number | null {
  try {
    const v = JSON.parse(localStorage.getItem(ESTIMATE_KEY) ?? "null") as { kbps: number; at: number } | null;
    if (v && Date.now() - v.at < ESTIMATE_MAX_AGE && v.kbps > 0) return v.kbps;
  } catch {
    /* ignore */
  }
  return null;
}

let estimate: number | null = savedEstimate() ?? initialEstimate();

function computeBudget(): number | null {
  if (pref !== "auto") return MANUAL[pref];
  if (estimate == null) return null;
  const half = estimate / 2;
  if (half >= UNLIMITED_ABOVE) return null;
  let b = STEPS[0];
  for (const s of STEPS) if (s <= half) b = s;
  return b;
}

let budget = computeBudget();

/** Called for new measurements only, so the 30-minute age counts from the last real one. */
function saveEstimate() {
  if (estimate == null) return;
  try {
    localStorage.setItem(ESTIMATE_KEY, JSON.stringify({ kbps: Math.round(estimate), at: Date.now() }));
  } catch {
    /* ignore */
  }
}

function publish() {
  budget = computeBudget();
  useStore.setState({ qualityBudget: budget, netKbps: estimate == null ? null : Math.round(estimate) });
}
publish();

export const getQualityPref = () => pref;
export function setQualityPref(p: QualityPref) {
  pref = p;
  try {
    localStorage.setItem(KEY, p);
  } catch {
    /* ignore */
  }
  publish();
}

/** Current bitrate budget (kbps) for new streams; null = no limit. */
export const qualityBudget = () => budget;

/** Query-string arguments for `/stream` and `/source`. */
export function qualityArgs(): string[] {
  const out: string[] = [];
  if (budget != null) out.push(`kbps=${budget}`);
  if (!opusOk) out.push("opus=0");
  return out;
}

/** A measured download speed from the server, in kbps. Drops count fast, rises slowly. */
export function reportSpeed(kbps: number) {
  if (!isFinite(kbps) || kbps <= 0) return;
  estimate = estimate == null ? kbps : kbps < estimate ? 0.6 * kbps + 0.4 * estimate : 0.3 * kbps + 0.7 * estimate;
  saveEstimate();
  publish();
}

/**
 * Playback stalled mid-song: the connection can't keep up with `streamKbps`.
 * Returns true when that lowers the budget below the current stream's bitrate.
 */
export function reportStall(streamKbps: number | null): boolean {
  const kbps = streamKbps ?? 130;
  // At most ~70% of the stream's rate got through.
  const cap = kbps * 0.7;
  estimate = estimate == null ? cap : Math.min(estimate, cap);
  saveEstimate();
  publish();
  return pref === "auto" && budget != null && budget < kbps;
}
