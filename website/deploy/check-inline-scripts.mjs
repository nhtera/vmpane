// SPDX-License-Identifier: Apache-2.0

// Reads a page's HTML on stdin and its Content-Security-Policy as the first
// argument; fails if an inline script's SHA-256 is not in script-src. A
// script Cloudflare injects (Rocket Loader, email obfuscation, analytics)
// would not be. No dependencies: the deploy job installs only cf.
// Same parsing as src/lib/security-headers.ts inlineScripts().

import { createHash } from "node:crypto";

const csp = process.argv[2] ?? "";
const allowed = new Set([...csp.matchAll(/'sha256-([^']+)'/g)].map((m) => m[1]));
let html = "";
for await (const chunk of process.stdin) html += chunk;
const NUL = String.fromCharCode(0);
const bad = [];
for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
  if (/\ssrc\s*=/i.test(m[1]) || m[2].length === 0) continue;
  const text = m[2].replace(/\r\n?/g, "\n").split(NUL).join("�");
  const hash = createHash("sha256").update(text).digest("base64");
  if (!allowed.has(hash)) bad.push(text.slice(0, 80));
}
if (bad.length) {
  console.error(`inline scripts not in the CSP:\n  ${bad.join("\n  ")}`);
  process.exit(1);
}
