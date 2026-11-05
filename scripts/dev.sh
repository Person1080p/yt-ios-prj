#!/usr/bin/env bash
# Runs the backend and the Vite dev server (with /api proxied) together.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$root/server" && cargo run) &
backend=$!
trap 'kill $backend 2>/dev/null' EXIT
cd "$root/web" && npm run dev
