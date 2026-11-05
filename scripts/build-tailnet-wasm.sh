#!/usr/bin/env bash
# Builds the in-browser Tailscale node (web/tailnet) to web/public/tailnet/.
# Requires Go (the version tailscale.com's go.mod asks for; GOTOOLCHAIN=auto fetches it).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/web/tailnet"
out="$root/web/public/tailnet"
mkdir -p "$out"
tags="$(go run ./internal/tags)"
echo "building tailnet.wasm…"
GOOS=js GOARCH=wasm go build -tags "$tags" -trimpath -ldflags "-s -w" -o "$out/tailnet.wasm" .
# wasm_exec.js must come from the same Go toolchain that built the module.
gojs="$(go env GOROOT)/lib/wasm/wasm_exec.js"
[ -f "$gojs" ] || gojs="$(go env GOROOT)/misc/wasm/wasm_exec.js"
cp "$gojs" "$out/wasm_exec.js"
ls -lh "$out"
