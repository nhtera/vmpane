// SPDX-License-Identifier: Apache-2.0

import { cloudflare } from "@cloudflare/vite-plugin";
import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import { fumadocsMdx } from "fumadocs-mdx/vite";
import { randomUUID } from "node:crypto";
import { defineConfig } from "vite";
import { recordInputs } from "./scripts/record-inputs.mjs";

// Prerender requests carry this per-build token. It only exists in the
// prerender Worker; the Worker that is deployed is rebuilt from a 404-only
// entry (scripts/build-worker.mjs) and has no render path at all. Kept in the
// environment so every load of this config in one build sees the same value.
const prerenderToken = (process.env.VMPANE_PRERENDER_TOKEN ??= randomUUID());

export default defineConfig({
  server: { port: 3100 },
  define: { __VMPANE_PRERENDER_TOKEN__: JSON.stringify(prerenderToken) },
  plugins: [
    fumadocsMdx(),
    tailwindcss(),
    cloudflare({ viteEnvironment: { name: "ssr" } }),
    tanstackStart({
      prerender: {
        enabled: true,
        crawlLinks: true,
        failOnError: true,
        headers: { "x-vmpane-prerender": prerenderToken },
        // A link with an anchor is the same page; render it once.
        filter: (page) => !page.path.includes("#"),
      },
      // Routes no page links to: the search and docs indexes, the 404 page,
      // sitemap, robots, llms.txt and the share card (captured to og.png).
      pages: [
        { path: "/api/search.json" },
        { path: "/api/docs-tree.json" },
        { path: "/404.html" },
        { path: "/sitemap.xml" },
        { path: "/robots.txt" },
        { path: "/llms.txt" },
        { path: "/og-card" },
      ],
    }),
    react(),
    recordInputs(),
  ],
  resolve: {
    tsconfigPaths: true,
  },
});
