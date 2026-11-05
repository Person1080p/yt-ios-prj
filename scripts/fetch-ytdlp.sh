#!/usr/bin/env bash
# Downloads the standalone yt-dlp binary into server/vendor/ so it can be baked into
# the server with `cargo build --release --features embed-ytdlp`.
set -euo pipefail
cd "$(dirname "$0")/../server"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  asset=yt-dlp_linux ;;
  Linux-aarch64) asset=yt-dlp_linux_aarch64 ;;
  Linux-armv7l)  asset=yt-dlp_linux_armv7l ;;
  Darwin-*)      asset=yt-dlp_macos ;;
  *)             asset=yt-dlp ;;
esac
mkdir -p vendor
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}" -o vendor/yt-dlp
chmod +x vendor/yt-dlp
echo "saved server/vendor/yt-dlp ($(vendor/yt-dlp --version))"
