#!/usr/bin/env bash
# Runs the ytp server and the Vite dev server (which forwards /api to it) together.
# Open the Vite address it prints (port 5173); stop both with Ctrl-C.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# rustup / Go installs often aren't on PATH in a fresh shell.
for d in "$HOME/.cargo/bin" "$HOME/.local/go/bin" "/usr/local/go/bin" "$HOME/go/bin"; do
  [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
done
export PATH

if ! command -v cargo >/dev/null; then
  echo "error: cargo not found — install Rust from https://rustup.rs (or add ~/.cargo/bin to PATH)" >&2
  exit 1
fi

# The server's address, from server/.env (YTP_BIND), so Vite forwards /api to the right place.
bind="$(grep -E '^YTP_BIND=' "$root/server/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
bind="${bind:-127.0.0.1:8080}"
bind="${bind/0.0.0.0/127.0.0.1}"
export YTP_BACKEND="${YTP_BACKEND:-http://$bind}"

echo "==> building and starting the ytp server (first build takes a few minutes)…"
(cd "$root/server" && cargo run) &
backend=$!
trap 'kill $backend 2>/dev/null || true' EXIT

# Wait for the server before starting Vite, and stop if it fails to build or start.
until curl -fs "$YTP_BACKEND/api/auth/check" >/dev/null 2>&1; do
  if ! kill -0 "$backend" 2>/dev/null; then
    wait "$backend" || true
    echo "error: the ytp server exited before it started — see the output above" >&2
    exit 1
  fi
  sleep 1
done
echo "==> ytp server is up at $YTP_BACKEND; starting Vite"

(cd "$root/web" && exec npm run dev) &
vite=$!
trap 'kill $backend $vite 2>/dev/null || true' EXIT

# If either one stops, stop the other too (no Vite left running without its server).
wait -n "$backend" "$vite" || true
if ! kill -0 "$backend" 2>/dev/null; then
  echo "error: the ytp server stopped — stopping Vite too" >&2
  exit 1
fi
