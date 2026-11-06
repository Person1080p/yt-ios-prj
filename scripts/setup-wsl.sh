#!/usr/bin/env bash
# Installs what scripts/dev.sh needs inside a WSL (or any Debian/Ubuntu) distro:
# a C toolchain and ffmpeg (apt), Rust (rustup, ~/.cargo), Go (~/.local/go) and Node (~/.local/node).
# Safe to re-run: anything already installed is skipped.
#
#   scripts/setup-wsl.sh          everything (uses sudo for the apt step)
#   scripts/setup-wsl.sh system   only the apt step (run as root, e.g. `wsl -u root`)
#   scripts/setup-wsl.sh user     only Rust, Go and Node (no root needed)
set -euo pipefail
mode="${1:-all}"
node_major=22

has() { command -v "$1" >/dev/null 2>&1; }
# Ignore Windows binaries that WSL puts on PATH (e.g. /mnt/c/Program Files/nodejs/npm).
has_linux() { local p; p="$(command -v "$1" 2>/dev/null)" && [[ "$p" != /mnt/* ]]; }

PATH="$HOME/.cargo/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH"

if [[ "$mode" == all || "$mode" == system ]]; then
  if ! has cc || ! has make || ! has pkg-config || ! has xz || ! has curl || ! has ffmpeg; then
    echo "==> installing build tools and ffmpeg (apt)…"
    sudo_=""; [[ $EUID -ne 0 ]] && sudo_="sudo"
    $sudo_ apt-get update -qq
    # dpkg is chatty even with -qq; errors still reach stderr.
    DEBIAN_FRONTEND=noninteractive $sudo_ apt-get install -y -qq build-essential pkg-config curl xz-utils ca-certificates ffmpeg >/dev/null
  fi
fi

[[ "$mode" == system ]] && exit 0

if ! has_linux cargo; then
  echo "==> installing Rust (rustup)…"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi

if ! has_linux go; then
  ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
  echo "==> installing $ver to ~/.local/go…"
  mkdir -p "$HOME/.local"
  rm -rf "$HOME/.local/go"
  curl -fsSL "https://go.dev/dl/$ver.linux-amd64.tar.gz" | tar -xz -C "$HOME/.local"
fi

if ! has_linux node; then
  base="https://nodejs.org/dist/latest-v$node_major.x"
  file="$(curl -fsSL "$base/SHASUMS256.txt" | grep -o 'node-v[0-9.]*-linux-x64\.tar\.xz' | head -1)"
  echo "==> installing ${file%.tar.xz} to ~/.local/node…"
  mkdir -p "$HOME/.local"
  rm -rf "$HOME/.local/node"
  tmp="$(mktemp -d)"
  curl -fsSL "$base/$file" | tar -xJ -C "$tmp"
  mv "$tmp"/node-v* "$HOME/.local/node"
  rmdir "$tmp"
fi

# Put the user-local installs on PATH for interactive shells too.
line='export PATH="$HOME/.cargo/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH"'
grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || printf '\n%s\n' "$line" >> "$HOME/.bashrc"

echo "==> toolchain ready: $(cargo --version), $(go version | cut -d' ' -f3), node $(node --version)"
