import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";

const backend = process.env.YTP_BACKEND ?? "http://127.0.0.1:8080";

// Cache-busting version for the in-page Tailscale module (public/tailnet/tailnet.wasm).
const wasmPath = new URL("./public/tailnet/tailnet.wasm", import.meta.url);
const tailnetVersion = existsSync(wasmPath)
  ? createHash("sha256").update(readFileSync(wasmPath)).digest("hex").slice(0, 12)
  : "missing";

export default defineConfig({
  define: { __TAILNET_VERSION__: JSON.stringify(tailnetVersion) },
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      includeAssets: ["icon.svg", "apple-touch-icon.png"],
      manifest: {
        name: "YTP Music",
        short_name: "YTP",
        description: "Self-hosted music player: YouTube Music, Plex and Last.fm",
        theme_color: "#0f0f12",
        background_color: "#0f0f12",
        display: "standalone",
        orientation: "portrait",
        start_url: "/",
        scope: "/",
        icons: [
          { src: "icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        // API calls (and especially audio streams) must always hit the server.
        navigateFallbackDenylist: [/^\/api\//],
        globIgnores: ["tailnet/**", "**/*.gz"],
        runtimeCaching: [
          {
            // The ~28 MB Tailscale WASM module: versioned URL, so cache it forever once downloaded.
            urlPattern: ({ url }) => url.pathname.startsWith("/tailnet/"),
            handler: "CacheFirst",
            options: { cacheName: "tailnet", expiration: { maxEntries: 4 }, cacheableResponse: { statuses: [200] } },
          },
          {
            urlPattern: ({ url }) => /googleusercontent\.com|ggpht\.com|ytimg\.com/.test(url.hostname),
            handler: "CacheFirst",
            options: {
              cacheName: "artwork",
              expiration: { maxEntries: 800, maxAgeSeconds: 60 * 60 * 24 * 30 },
              cacheableResponse: { statuses: [0, 200] },
            },
          },
        ],
      },
    }),
  ],
  server: {
    host: true,
    proxy: { "/api": { target: backend, changeOrigin: false } },
  },
});
