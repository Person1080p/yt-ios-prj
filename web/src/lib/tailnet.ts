// In-page Tailscale node (Go → WebAssembly, see web/tailnet/main.go).
//
// The page itself joins your tailnet — no Tailscale app or OS VPN on the device.
// Browsers can't send UDP, so all traffic is relayed through Tailscale's DERP
// servers over WebSockets (end-to-end WireGuard encrypted). That is plenty for
// music, but is slower than a direct connection.

import { create } from "zustand";

declare const __TAILNET_VERSION__: string;
declare global {
  // Provided by Go's wasm_exec.js
  // eslint-disable-next-line no-var
  var Go: { new (): { importObject: WebAssembly.Imports; run(i: WebAssembly.Instance): Promise<void> } };
  // eslint-disable-next-line no-var
  var newTailnet: ((cfg: unknown) => TailnetNode) | undefined;
}

type TailnetResponse = {
  status: number;
  statusText: string;
  headers: [string, string][];
  read(): Promise<Uint8Array | null>;
  cancel(): void;
};

type TailnetNode = {
  run(cb: {
    notifyState(s: string): void;
    notifyNetMap(json: string): void;
    notifyBrowseToURL(url: string): void;
    notifyPanicRecover(err: string): void;
  }): void;
  login(): void;
  logout(): void;
  fetch(req: { url: string; method: string; headers: [string, string][]; body?: Uint8Array }): Promise<TailnetResponse>;
};

export type Peer = { name: string; addresses: string[]; online?: boolean; os?: string };

export type TailnetState = {
  phase: "idle" | "loading" | "starting" | "needs-login" | "needs-approval" | "running" | "error";
  backendState?: string;
  loginUrl?: string;
  self?: Peer;
  peers: Peer[];
  error?: string;
};

export const useTailnet = create<TailnetState>(() => ({ phase: "idle", peers: [] }));
const set = useTailnet.setState;

const STATE_PREFIX = "ytp.ts.";
const stateStorage = {
  getState: (k: string) => {
    try {
      return localStorage.getItem(STATE_PREFIX + k) ?? "";
    } catch {
      return "";
    }
  },
  setState: (k: string, v: string) => {
    try {
      localStorage.setItem(STATE_PREFIX + k, v);
    } catch {
      /* storage full / disabled */
    }
  },
};

let node: TailnetNode | null = null;
let starting: Promise<void> | null = null;
let runningWaiters: { resolve: () => void; reject: (e: Error) => void }[] = [];

const version = typeof __TAILNET_VERSION__ === "string" ? __TAILNET_VERSION__ : "dev";

function loadScript(src: string) {
  return new Promise<void>((resolve, reject) => {
    const s = document.createElement("script");
    s.src = src;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error(`failed to load ${src}`));
    document.head.appendChild(s);
  });
}

let warmed = false;

/**
 * Download the module so the service worker has it cached for when the fallback is needed
 * (e.g. opening the app away from home, where this address can't serve it). Doesn't start it.
 */
export function warmTailnetCache() {
  if (warmed || node) return;
  warmed = true;
  for (const f of ["wasm_exec.js", "tailnet.wasm"]) {
    fetch(`/tailnet/${f}?v=${version}`)
      .then((r) => r.arrayBuffer())
      .catch(() => {
        warmed = false;
      });
  }
}

async function loadWasm(): Promise<void> {
  if (!globalThis.Go) await loadScript(`/tailnet/wasm_exec.js?v=${version}`);
  const go = new globalThis.Go();
  const url = `/tailnet/tailnet.wasm?v=${version}`;
  let instance: WebAssembly.Instance;
  try {
    instance = (await WebAssembly.instantiateStreaming(fetch(url), go.importObject)).instance;
  } catch {
    // Some static hosts serve .wasm with the wrong MIME type.
    const buf = await (await fetch(url)).arrayBuffer();
    instance = (await WebAssembly.instantiate(buf, go.importObject)).instance;
  }
  go.run(instance).catch((e) => set({ phase: "error", error: `Tailscale runtime exited: ${e}` }));
  for (let i = 0; i < 100 && !globalThis.newTailnet; i++) await new Promise((r) => setTimeout(r, 20));
  if (!globalThis.newTailnet) throw new Error("tailnet module did not initialise");
}

/** Boot the in-page node (idempotent). Persisted state means it reconnects silently after the first login. */
export function startTailnet(opts: { hostname: string; authKey?: string }): Promise<void> {
  if (starting) return starting;
  starting = (async () => {
    set({ phase: "loading", error: undefined });
    try {
      await loadWasm();
    } catch (e) {
      starting = null;
      set({ phase: "error", error: (e as Error).message });
      throw e;
    }
    set({ phase: "starting" });
    node = globalThis.newTailnet!({
      stateStorage,
      hostname: opts.hostname,
      authKey: opts.authKey || undefined,
      ephemeral: false,
    });
    node.run({
      notifyState(s) {
        const phase: TailnetState["phase"] =
          s === "Running"
            ? "running"
            : s === "NeedsLogin"
              ? "needs-login"
              : s === "NeedsMachineAuth"
                ? "needs-approval"
                : "starting";
        set({ backendState: s, phase });
        if (s === "NeedsLogin" && !opts.authKey) node?.login();
        if (phase === "running") {
          set({ loginUrl: undefined });
          runningWaiters.forEach((w) => w.resolve());
          runningWaiters = [];
        } else if (phase === "needs-login" || phase === "needs-approval") {
          // Requests can't succeed until the user finishes setup in Settings; don't leave them hanging.
          runningWaiters.forEach((w) => w.reject(notReady()));
          runningWaiters = [];
        }
      },
      notifyNetMap(json) {
        try {
          const nm = JSON.parse(json);
          set({ self: nm.self, peers: (nm.peers ?? []).sort((a: Peer, b: Peer) => Number(!!b.online) - Number(!!a.online)) });
        } catch {
          /* ignore */
        }
      },
      notifyBrowseToURL(url) {
        set({ loginUrl: url });
      },
      notifyPanicRecover(err) {
        console.error("tailnet panic:", err);
      },
    });
  })();
  return starting;
}

export function tailnetLogin() {
  node?.login();
}

export function tailnetLogout() {
  node?.logout();
  try {
    Object.keys(localStorage)
      .filter((k) => k.startsWith(STATE_PREFIX))
      .forEach((k) => localStorage.removeItem(k));
  } catch {
    /* ignore */
  }
}

const notReady = () => {
  const e = new Error("Not connected to your tailnet — finish setup in Settings → Connection");
  e.name = "NotConnectedError"; // the app shows its connection banner instead of per-page errors
  return e;
}

/** Resolves once the node is up. Fails immediately if it's waiting on the user (sign-in/approval) or not started. */
export function waitRunning(timeoutMs = 60000): Promise<void> {
  const phase = useTailnet.getState().phase;
  if (phase === "running") return Promise.resolve();
  if (phase !== "loading" && phase !== "starting") return Promise.reject(notReady());
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("Timed out connecting to your tailnet")), timeoutMs);
    runningWaiters.push({
      resolve: () => {
        clearTimeout(t);
        resolve();
      },
      reject: (e) => {
        clearTimeout(t);
        reject(e);
      },
    });
  });
}

async function bodyBytes(body: BodyInit | null | undefined): Promise<Uint8Array | undefined> {
  if (body == null) return undefined;
  if (typeof body === "string") return new TextEncoder().encode(body);
  if (body instanceof Uint8Array) return body;
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  if (body instanceof Blob) return new Uint8Array(await body.arrayBuffer());
  return new Uint8Array(await new Response(body).arrayBuffer());
}

/** fetch() over the tailnet. Returns a real streaming `Response`. */
export async function tailnetFetch(url: string, init: RequestInit = {}): Promise<Response> {
  await waitRunning();
  if (!node) throw new Error("tailnet not started");
  const headers: [string, string][] = [];
  new Headers(init.headers).forEach((v, k) => headers.push([k, v]));
  const res = await node.fetch({
    url,
    method: init.method ?? "GET",
    headers,
    body: await bodyBytes(init.body),
  });
  init.signal?.addEventListener("abort", () => res.cancel());
  if (init.signal?.aborted) {
    res.cancel();
    throw new DOMException("Aborted", "AbortError");
  }
  const nullBody = [101, 204, 205, 304].includes(res.status) || init.method === "HEAD";
  const stream = nullBody
    ? null
    : new ReadableStream<Uint8Array>({
        async pull(controller) {
          try {
            const chunk = await res.read();
            if (chunk === null) controller.close();
            else controller.enqueue(chunk);
          } catch (e) {
            controller.error(e);
          }
        },
        cancel() {
          res.cancel();
        },
      });
  return new Response(stream, { status: res.status, statusText: res.statusText, headers: res.headers });
}
