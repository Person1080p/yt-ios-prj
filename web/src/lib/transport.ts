// How this device reaches the ytp server.
//
// Rule: if the server answers at this page's own address, talk to it directly — always.
// The in-page Tailscale node (WebAssembly) is only a *fallback*, used when the page's
// address can't reach the server (e.g. the app is served from a public static host, or
// it was installed from the server and is now opened away from home, from the
// service-worker cache). Reachability is re-checked on launch, on resume, when the
// network changes, when direct requests start failing, and periodically while on the
// fallback, so the app switches back to direct as soon as it can.

import { create } from "zustand";
import { startTailnet, tailnetFetch, useTailnet, warmTailnetCache } from "./tailnet";

export type TailnetConfig = { server: string; hostname: string; authKey?: string };
export type Connection = { mode: "direct" } | ({ mode: "tailnet" } & TailnetConfig);

const TAILNET_KEY = "ytp.tailnet";
const LEGACY_KEY = "ytp.conn";
const TOKEN_KEY = "ytp.token";
const SERVER_KEY = "ytp.server";
const PROBE_TIMEOUT_MS = 4000;
const RECHECK_MS = 60_000;

function readTailnetConfig(): TailnetConfig | null {
  try {
    const raw = localStorage.getItem(TAILNET_KEY);
    if (raw) return JSON.parse(raw) as TailnetConfig;
    // Migrate the earlier "active connection" format.
    const legacy = localStorage.getItem(LEGACY_KEY);
    if (legacy) {
      localStorage.removeItem(LEGACY_KEY);
      const c = JSON.parse(legacy);
      if (c?.mode === "tailnet") {
        const cfg = { server: c.server, hostname: c.hostname, authKey: c.authKey };
        localStorage.setItem(TAILNET_KEY, JSON.stringify(cfg));
        return cfg;
      }
    }
  } catch {
    /* ignore */
  }
  return null;
}

/** What we learned about the server while connected directly — used to pre-fill the fallback. */
export type KnownServer = {
  /** Page origin that served the API. */
  origin: string;
  /** The server's own address on the tailnet, as it reports it (null if it isn't reachable there). */
  tailnetUrl: string | null;
  /** Its tailnet name / addresses, to recognise it in the device list. */
  tailnetName?: string | null;
  tailnetIps?: string[];
};

function readKnownServer(): KnownServer | null {
  try {
    const raw = localStorage.getItem(SERVER_KEY);
    return raw ? (JSON.parse(raw) as KnownServer) : null;
  } catch {
    return null;
  }
}

type ConnState = {
  /** The connection in use right now (null = none works / not determined yet). */
  conn: Connection | null;
  /** Saved in-page Tailscale fallback. */
  tailnet: TailnetConfig | null;
  /** Result of the last check of the page's own address (null = not checked yet). */
  directAvailable: boolean | null;
  /**
   * The page's own address answered, but its /api isn't a ytp server — e.g. the Vite dev
   * server is running but the ytp server it forwards to isn't. Tailscale can't fix that.
   */
  pageWithoutServer: boolean;
  knownServer: KnownServer | null;
};

export const useConnection = create<ConnState>(() => ({
  conn: null,
  tailnet: readTailnetConfig(),
  directAvailable: null,
  pageWithoutServer: false,
  knownServer: readKnownServer(),
}));
const set = useConnection.setState;
const get = useConnection.getState;

export class NotConnectedError extends Error {
  constructor(msg = "Not connected to your ytp server — set up the connection in Settings") {
    super(msg);
    this.name = "NotConnectedError";
  }
}

export function getConnection(): Connection | null {
  return get().conn;
}

export const isTailnet = () => getConnection()?.mode === "tailnet";

// ---- detection --------------------------------------------------------------------------

/** Does a ytp API answer at this page's own origin? */
async function probeDirect(): Promise<boolean> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), PROBE_TIMEOUT_MS);
  try {
    const r = await fetch("/api/auth/check", { cache: "no-store", signal: ctrl.signal });
    const ok = r.ok && (r.headers.get("content-type") ?? "").includes("json") && typeof (await r.json())?.required === "boolean";
    // Something answered at this address (it served this page), just not the ytp API.
    set({ pageWithoutServer: !ok });
    return ok;
  } catch {
    set({ pageWithoutServer: false });
    return false;
  } finally {
    clearTimeout(t);
  }
}

function choose(direct: boolean): Connection | null {
  if (direct) return { mode: "direct" };
  const tn = get().tailnet;
  return tn ? { mode: "tailnet", ...tn } : null;
}

function apply(conn: Connection | null, direct: boolean) {
  const prev = get().conn;
  const same = JSON.stringify(prev) === JSON.stringify(conn);
  set({ directAvailable: direct, ...(same ? {} : { conn }) });
  // Only ever bring the tailnet node up when it is actually needed.
  if (conn?.mode === "tailnet") startTailnet({ hostname: conn.hostname, authKey: conn.authKey }).catch(() => {});
  if (conn?.mode === "direct") {
    learnServer();
    // Make sure the fallback can start later even if this address is unreachable then
    // (the service worker caches the module). Downloads only — nothing runs.
    if (get().tailnet) warmTailnetCache();
  }
}

let learned = false;

/** While connected directly, ask the server for its own tailnet address and remember it. */
async function learnServer() {
  if (learned) return;
  learned = true;
  try {
    const r = await fetch("/api/status", { ...withAuth({}), credentials: "same-origin", cache: "no-store" });
    if (!r.ok) return;
    rememberServerStatus(await r.json());
  } catch {
    learned = false;
  }
}

/** Record what the server says about itself (called whenever its status is fetched directly). */
export function rememberServerStatus(status: { tailscale?: { url?: string | null; dnsName?: string | null; ips?: string[] } }) {
  if (getConnection()?.mode !== "direct") return;
  const ts = status?.tailscale;
  const known: KnownServer = {
    origin: location.origin,
    tailnetUrl: ts?.url ?? null,
    tailnetName: ts?.dnsName ?? null,
    tailnetIps: ts?.ips ?? [],
  };
  try {
    localStorage.setItem(SERVER_KEY, JSON.stringify(known));
  } catch {
    /* ignore */
  }
  set({ knownServer: known });
}

/**
 * Tailnet nodes this app creates for browsers/phones (ytp-browser, ytp-iphone-2, …).
 * They run the web app, never the server.
 */
export function isBrowserNode(nameOrUrl: string) {
  let h = nameOrUrl.trim();
  try {
    if (/^https?:\/\//.test(h)) h = new URL(h).hostname;
  } catch {
    /* plain name */
  }
  return /^ytp-(browser|iphone|ipad|android)(-\d+)?(\.|$)/i.test(h);
}

/** localhost / 127.x / ::1 — over the tailnet these would mean the browser's own node, never the server. */
export function isLoopbackUrl(u: string) {
  try {
    const h = new URL(normalizeServer(u)).hostname.replace(/^\[|\]$/g, "");
    return h === "localhost" || h.endsWith(".localhost") || h === "::1" || /^127\./.test(h) || h === "0.0.0.0";
  } catch {
    return false;
  }
}

let inflight: Promise<Connection | null> | null = null;
let detected = false;

/**
 * Work out which connection to use. Cheap to call repeatedly: concurrent calls share one
 * probe, and after the first result it only re-probes when `force` is set.
 */
export function detectConnection(force = false): Promise<Connection | null> {
  if (inflight) return inflight;
  if (detected && !force) return Promise.resolve(get().conn);
  inflight = probeDirect()
    .then((direct) => {
      const conn = choose(direct);
      apply(conn, direct);
      detected = true;
      return conn;
    })
    .finally(() => {
      inflight = null;
    });
  return inflight;
}

let watching = false;

/** Keep re-checking so we fail over to Tailscale, and back to direct, automatically. */
export function watchConnection() {
  if (watching) return;
  watching = true;
  detectConnection();
  const recheck = () => detectConnection(true);
  window.addEventListener("online", recheck);
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && recheck());
  setInterval(() => {
    // While on the fallback (or disconnected), look for the direct route coming back.
    if (get().conn?.mode !== "direct" && document.visibilityState === "visible") recheck();
  }, RECHECK_MS);
}

// ---- tailnet fallback config -------------------------------------------------------------------

/** Save (or clear) the in-page Tailscale fallback. It becomes active only if direct doesn't work. */
export function setTailnetConfig(cfg: TailnetConfig | null) {
  try {
    if (cfg) localStorage.setItem(TAILNET_KEY, JSON.stringify(cfg));
    else localStorage.removeItem(TAILNET_KEY);
  } catch {
    /* ignore */
  }
  set({ tailnet: cfg });
  if (cfg) warmTailnetCache();
  const direct = get().directAvailable ?? false;
  apply(choose(direct), direct);
}

/**
 * Default server for the fallback: the server this app talks to. Prefer the address the
 * server reported for itself on the tailnet; otherwise this page's address, if it is (or was)
 * served by the ytp server and isn't a loopback address. Empty when neither is usable.
 */
export function suggestedTailnetServer(state: ConnState = get()): string {
  const k = state.knownServer;
  if (k?.tailnetUrl && !isBrowserNode(k.tailnetUrl)) return k.tailnetUrl;
  // The page's own address only helps if the tailnet can reach it (not localhost).
  const origin = k?.origin ?? (state.directAvailable ? location.origin : "");
  return origin && !isLoopbackUrl(origin) ? origin : "";
}

export function normalizeServer(s: string) {
  let v = s.trim().replace(/\/+$/, "");
  if (v && !/^https?:\/\//.test(v)) v = `http://${v}`;
  return v;
}

// ---- auth token -------------------------------------------------------------------------------

export function getToken() {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(t: string | null) {
  try {
    if (t) localStorage.setItem(TOKEN_KEY, t);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}

// ---- requests ----------------------------------------------------------------------------------

/** True once API calls can go through. */
export function useTransportReady() {
  const conn = useConnection((s) => s.conn);
  const phase = useTailnet((s) => s.phase);
  return conn?.mode === "direct" || (conn?.mode === "tailnet" && phase === "running");
}

function withAuth(init: RequestInit): RequestInit {
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token && !headers.has("authorization")) headers.set("authorization", `Bearer ${token}`);
  return { ...init, headers };
}

/** fetch() for `/api/...` paths: direct when the page's address works, otherwise the tailnet fallback. */
export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const conn = getConnection() ?? (await detectConnection());
  if (!conn) throw new NotConnectedError();
  const req = withAuth(init);

  if (conn.mode === "tailnet") return tailnetFetch(`${conn.server}/api${path}`, req);

  try {
    return await fetch(`/api${path}`, { ...req, credentials: "same-origin" });
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
    // The page's address stopped answering (left home Wi-Fi, server down…): re-check and
    // retry once over the tailnet fallback if that's what's available now.
    const next = await detectConnection(true);
    if (next?.mode === "tailnet") return tailnetFetch(`${next.server}/api${path}`, req);
    if (!next) throw new NotConnectedError("Your ytp server isn't reachable from here — set up the Tailscale fallback in Settings");
    throw e;
  }
}
