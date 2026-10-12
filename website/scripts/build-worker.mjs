// SPDX-License-Identifier: Apache-2.0

// Replaces the build's Worker with the 404-only Worker before deploy.
//
// `cf build` prerenders every page with a Worker that can render (src/server.ts,
// gated by a per-build token). That Worker must not reach production: if
// the token leaked (it is in the bundle), anyone could make the live site
// render on request. So the deployed Worker is built separately from
// src/worker/production.ts, which imports nothing from TanStack Start, and
// this script checks the result has no render path and no token.
//
//   node scripts/build-worker.mjs [bundle dir]

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "vite";
import { SITE_DIR, WORKER_DIR } from "./paths.mjs";

/** Strings that only the render path or the prerender gate contain. */
export const FORBIDDEN = ["x-vmpane-prerender", "__VMPANE_PRERENDER_TOKEN__", "VMPANE_PRERENDER_TOKEN", "@tanstack", "tanstack", "renderToReadableStream", "createStartHandler", "fumadocs"];

function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(dir, e.name)) : [join(dir, e.name)]));
}

/** Throws unless `dir` holds only index.js, without any forbidden string (or `token`, when given). */
export function checkWorkerBundle(dir, token = process.env.VMPANE_PRERENDER_TOKEN) {
  const all = files(dir).map((f) => relative(dir, f));
  if (all.length !== 1 || all[0] !== "index.js") throw new Error(`Worker bundle: expected only index.js, found ${all.join(", ")}`);
  const code = readFileSync(join(dir, "index.js"), "utf8");
  for (const needle of [...FORBIDDEN, ...(token ? [token] : [])]) {
    if (code.includes(needle)) throw new Error(`Worker bundle contains "${needle === token ? "<prerender token>" : needle}": the render path reached the deployed Worker`);
  }
  if (!code.includes("404.html")) throw new Error("Worker bundle does not serve 404.html");
  return code.length;
}

export async function buildWorker(outDir = WORKER_DIR) {
  await build({
    configFile: false,
    root: SITE_DIR,
    logLevel: "warn",
    build: {
      ssr: join(SITE_DIR, "src/worker/production.ts"),
      outDir,
      emptyOutDir: true,
      minify: false,
      target: "es2022",
      copyPublicDir: false,
      rollupOptions: { output: { format: "es", entryFileNames: "index.js" } },
    },
    ssr: { target: "webworker", noExternal: true },
  });
  return checkWorkerBundle(outDir);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dir = resolve(process.argv[2] ?? WORKER_DIR);
  if (!statSync(dir, { throwIfNoEntry: false })) throw new Error(`${dir}: no build output (run cf build first)`);
  const size = await buildWorker(dir);
  console.log(`deployed Worker: 404 only, ${size} bytes, no render path`);
}
