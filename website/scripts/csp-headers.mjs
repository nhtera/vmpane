// SPDX-License-Identifier: Apache-2.0

// Writes _headers into the built assets (after the build, before any check
// or deploy): security headers for every response, a Content-Security-Policy
// per page with the SHA-256 of each inline script on it (no
// 'unsafe-inline' for scripts), and immutable caching for hashed files.
//
//   node scripts/csp-headers.mjs [dir]

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { contentSecurityPolicy, IMMUTABLE, inlineScripts, SECURITY_HEADERS } from "../src/lib/security-headers.ts";
import { OUTPUT_DIR } from "./paths.mjs";

/** Cloudflare reads at most 100 rules from _headers. */
export const MAX_RULES = 100;

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("base64");

function htmlFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return htmlFiles(p);
    return e.name.endsWith(".html") ? [p] : [];
  });
}

/** The path a page is requested at: docs/x/index.html → /docs/x; 404.html → /404. */
export function requestPath(root, file) {
  const rel = relative(root, file).split(sep).join("/");
  const path = `/${rel.replace(/(^|\/)index\.html$/, "").replace(/\.html$/, "")}`;
  return path.length > 1 ? path.replace(/\/$/, "") : "/";
}

/** The _headers file for a built site. */
export function buildHeaders(root) {
  const rules = [
    ["/*", Object.entries(SECURITY_HEADERS)],
    ["/assets/*", [["Cache-Control", IMMUTABLE]]],
    ["/screens/*", [["Cache-Control", IMMUTABLE]]],
  ];
  for (const file of htmlFiles(root).sort()) {
    const hashes = inlineScripts(readFileSync(file, "utf8")).map(sha256);
    rules.push([requestPath(root, file), [["Content-Security-Policy", contentSecurityPolicy(hashes)]]]);
  }
  if (rules.length > MAX_RULES) {
    throw new Error(`_headers would have ${rules.length} rules; Cloudflare reads ${MAX_RULES}. Merge the page CSPs into one /* rule.`);
  }
  return `${rules.map(([path, headers]) => `${path}\n${headers.map(([k, v]) => `  ${k}: ${v}`).join("\n")}`).join("\n\n")}\n`;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = resolve(process.argv[2] ?? OUTPUT_DIR);
  const text = buildHeaders(root);
  writeFileSync(join(root, "_headers"), text);
  console.log(`_headers written (${text.match(/^\//gm).length} rules)`);
}
