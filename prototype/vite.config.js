import { defineConfig } from "vite";

// The preview environment proxies this server under https://{port}-{sandboxId}.e2b.app,
// so: bind every interface, allow any host, and disable the origin check.
export default defineConfig({
  // ../shared holds the seed feed that the iOS app reads too — one source of truth.
  publicDir: "../shared",
  server: {
    host: "0.0.0.0",
    port: 5173,
    strictPort: true,
    allowedHosts: true,
    fs: { allow: [".."] },
    hmr: { protocol: "wss", clientPort: 443 },
  },
  preview: {
    host: "0.0.0.0",
    port: 5173,
    allowedHosts: true,
  },
});
