import { useEffect, useRef, useState } from "react";
import { startTailnet, tailnetFetch, tailnetLogin, useTailnet, type Peer } from "../lib/tailnet";
import {
  isLoopbackUrl,
  normalizeServer,
  setTailnetConfig,
  suggestedTailnetServer,
  useConnection,
  type KnownServer,
} from "../lib/transport";

const shortName = (fqdn: string) => fqdn.replace(/\.$/, "").split(".")[0];

/**
 * Turns on "away-from-home access" for this browser: sign the browser in to Tailscale, then
 * connect to the server. The server's tailnet address is normally already known (the server
 * reports it), so that part happens automatically; picking a server by hand is only offered
 * when it isn't known or doesn't answer.
 */
export default function TailnetSetup({ onSaved }: { onSaved?: () => void }) {
  const saved = useConnection((s) => s.tailnet);
  const known = useConnection((s) => s.knownServer);
  const suggestion = useConnection((s) => suggestedTailnetServer(s));
  const ts = useTailnet();

  const [hostname, setHostname] = useState(saved?.hostname ?? defaultHostname());
  const [authKey, setAuthKey] = useState("");
  const [server, setServer] = useState(saved?.server ?? suggestion);
  const [manual, setManual] = useState(!saved?.server && !suggestion);
  const [testing, setTesting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const autoTried = useRef(false);

  useEffect(() => {
    // The server's address may become known after this opens.
    if (!manual && !saved && suggestion) setServer(suggestion);
  }, [suggestion, saved, manual]);

  const running = ts.phase === "running";
  const busy = ts.phase === "loading" || ts.phase === "starting";
  const serverPeer = ts.peers.find((p) => isServerPeer(p, known));

  const signIn = async () => {
    setError(null);
    try {
      await startTailnet({ hostname: hostname.trim() || defaultHostname(), authKey: authKey.trim() || undefined });
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const connect = async (target = server) => {
    const url = normalizeServer(target);
    if (!url) return;
    if (isLoopbackUrl(url)) {
      setError(`${url} is a loopback address — over the tailnet it would point at this browser, not your server.`);
      setManual(true);
      return;
    }
    setTesting(true);
    setError(null);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15000);
    try {
      const r = await tailnetFetch(`${url}/api/auth/check`, { signal: ctrl.signal }).catch((e) => {
        throw ctrl.signal.aborted ? new Error("no answer within 15 s") : e;
      });
      const j = await r.json().catch(() => null);
      if (!r.ok || typeof j?.required !== "boolean") throw new Error(`it answered, but isn't a ytp server (HTTP ${r.status})`);
      setTailnetConfig({ server: url, hostname: hostname.trim() || defaultHostname() });
      onSaved?.();
    } catch (e) {
      setError(`Couldn't reach your server at ${url} over Tailscale: ${(e as Error).message}`);
      setManual(true);
    } finally {
      clearTimeout(timer);
      setTesting(false);
    }
  };

  // Once signed in, connect to the known server address without asking.
  useEffect(() => {
    if (running && !manual && server && !autoTried.current) {
      autoTried.current = true;
      connect(server);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [running, manual, server]);

  return (
    <div className="tailnet-setup">
      {/* Step 1: this browser joins the tailnet */}
      {ts.phase === "idle" || ts.phase === "error" ? (
        <div className="setup-step">
          <label className="field">
            <span>Name for this device on your tailnet</span>
            <input className="input" value={hostname} onChange={(e) => setHostname(e.target.value)} />
          </label>
          <details className="small">
            <summary className="muted">Use an auth key instead of signing in</summary>
            <input className="input" placeholder="tskey-auth-…" value={authKey} onChange={(e) => setAuthKey(e.target.value)} />
            <p className="muted small">Create one under Settings → Keys in the Tailscale admin console.</p>
          </details>
          <button className="btn" onClick={signIn}>
            Sign this browser in to Tailscale
          </button>
        </div>
      ) : busy ? (
        <p className="small muted">{ts.phase === "loading" ? "Loading Tailscale (≈6 MB, first time only)…" : "Connecting to Tailscale…"}</p>
      ) : ts.phase === "needs-login" ? (
        <div className="setup-step">
          {ts.loginUrl ? (
            <>
              <a className="btn" href={ts.loginUrl} target="_blank" rel="noreferrer">
                Sign this browser in to Tailscale
              </a>
              <p className="muted small">Approve the device in the tab that opens; this continues by itself.</p>
            </>
          ) : (
            <button className="btn ghost" onClick={tailnetLogin}>
              Get sign-in link
            </button>
          )}
        </div>
      ) : ts.phase === "needs-approval" ? (
        <p className="warn-text small">Signed in — waiting for this device to be approved in the Tailscale admin console.</p>
      ) : (
        <p className="small">
          <span className="dot ok" /> This browser is on your tailnet as <code>{ts.self?.name?.replace(/\.$/, "")}</code>.
        </p>
      )}

      {/* Step 2: reach the server — automatic when its address is known */}
      {running && !manual && testing && (
        <p className="small">
          Connecting to your server at <code>{server}</code>…
        </p>
      )}
      {running && manual && (
        <div className="setup-step">
          <strong className="small">Which device is your ytp server?</strong>
          <input
            className="input"
            placeholder="ytp  ·  100.x.y.z:8080  ·  https://host.tailnet.ts.net"
            value={server}
            onChange={(e) => setServer(e.target.value)}
          />
          <PeerPicker peers={ts.peers} serverPeer={serverPeer} onPick={(p) => setServer(`http://${shortName(p.name)}`)} />
          <button className="btn" disabled={!server.trim() || testing} onClick={() => connect()}>
            {testing ? "Connecting…" : "Connect"}
          </button>
        </div>
      )}
      {running && !manual && !testing && (
        <button className="btn ghost small" onClick={() => setManual(true)}>
          Use a different server
        </button>
      )}

      {(error || ts.error) && <p className="error small">{error ?? ts.error}</p>}
    </div>
  );
}

/** Is this tailnet device the ytp server we know from the direct connection? */
function isServerPeer(p: Peer, known: KnownServer | null) {
  if (!known) return false;
  const name = (known.tailnetName ?? "").replace(/\.$/, "").toLowerCase();
  return (
    (!!name && p.name.replace(/\.$/, "").toLowerCase() === name) ||
    (p.addresses ?? []).some((a) => (known.tailnetIps ?? []).includes(a))
  );
}

function PeerPicker({ peers, serverPeer, onPick }: { peers: Peer[]; serverPeer?: Peer; onPick: (p: Peer) => void }) {
  if (!peers.length) return null;
  const sorted = serverPeer ? [serverPeer, ...peers.filter((p) => p !== serverPeer)] : peers;
  return (
    <div className="peer-list">
      <span className="muted small">Devices on your tailnet:</span>
      {sorted.map((p) => (
        <button key={p.name} className={`peer ${p === serverPeer ? "is-server" : ""}`} onClick={() => onPick(p)}>
          <span className={`dot ${p.online ? "ok" : "off"}`} />
          {shortName(p.name)}
          {p === serverPeer && <span className="badge youtube">ytp server</span>}
          <span className="muted small">{p.addresses?.[0]}</span>
        </button>
      ))}
    </div>
  );
}

function defaultHostname() {
  const ua = navigator.userAgent;
  const kind = /iPhone/.test(ua) ? "iphone" : /iPad/.test(ua) ? "ipad" : /Android/.test(ua) ? "android" : "browser";
  return `ytp-${kind}`;
}
