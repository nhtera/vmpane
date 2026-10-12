// SPDX-License-Identifier: Apache-2.0

// The Worker for vmpane.erai.dev (cf CLI and the Cloudflare Vite plugin).
//
// Every page is prerendered into the static assets, which are served before
// the Worker runs. The deployed Worker only sees paths with no page and
// answers them with 404.html, status 404 and the security headers. Its one
// binding is ASSETS (the site's own files); no secrets, no data bindings.
// No `domains`: vmpane.erai.dev is attached once by hand, so the deploy token
// needs no zone permissions.
import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "vmpane-website",
    compatibilityDate: "2026-10-01",
    compatibilityFlags: ["nodejs_compat"],
    entrypoint: "./src/server.ts",
    // /docs/x is docs/x/index.html; /docs/x/ redirects to /docs/x.
    assets: { htmlHandling: "drop-trailing-slash" },
    env: { ASSETS: bindings.assets() },
  },
});
