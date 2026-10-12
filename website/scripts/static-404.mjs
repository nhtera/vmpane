// SPDX-License-Identifier: Apache-2.0

// Makes 404.html a static page. It is served for every path that has no page,
// so it would hydrate at a URL the router does not know and re-render in its
// not-found state. The page has nothing interactive (plain links), so the app
// bundle and the hydration data are removed; the theme scripts stay.
//
//   node scripts/static-404.mjs [dir]

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { OUTPUT_DIR } from "./paths.mjs";

/** The page without module scripts, module preloads and TanStack hydration scripts. */
export function staticPage(html) {
  return html
    .replace(/<link rel="modulepreload"[^>]*>/g, "")
    .replace(/<script type="module"[^>]*><\/script>/g, "")
    .replace(/<script\b[^>]*>(?:(?!<\/script>)[\s\S])*?(\$_TSR|\$tsr-stream-boundary|self\.\$R)(?:(?!<\/script>)[\s\S])*<\/script>/g, "");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const file = join(resolve(process.argv[2] ?? OUTPUT_DIR), "404.html");
  const before = readFileSync(file, "utf8");
  const after = staticPage(before);
  if (/<script type="module"|\$_TSR/.test(after)) throw new Error("404.html: hydration scripts remain");
  writeFileSync(file, after);
  console.log(`404.html made static (${before.length - after.length} bytes of scripts removed)`);
}
