// SPDX-License-Identifier: Apache-2.0

// Serves the built site (scripts/paths.mjs OUTPUT_DIR) the way Cloudflare's
// static assets do with `drop-trailing-slash` and `404-page`: /docs/x is
// docs/x/index.html, /docs/x/ redirects to /docs/x, and a miss is 404.html
// with status 404. Every response carries the headers the build's `_headers`
// gives its path (a miss, those of /404), so the browser suites run under the
// production CSP. Text is brotli-compressed, as Cloudflare does, so
// audits see production-like transfer sizes. For the browser tests and local audits; the real
// Worker is exercised by `npm run preview`.
//
//   node scripts/serve-dist.mjs [port] [dir]

import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createBrotliCompress } from "node:zlib";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { headersFor, parseHeadersFile } from "./headers-file.mjs";
import { OUTPUT_DIR } from "./paths.mjs";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".xml": "application/xml",
  ".txt": "text/plain; charset=utf-8",
};

function isFile(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

export function startServer({ port = 0, dir = OUTPUT_DIR } = {}) {
  const root = resolve(dir);
  const headersFile = join(root, "_headers");
  const rules = existsSync(headersFile) ? parseHeadersFile(readFileSync(headersFile, "utf8")) : [];
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    let path = decodeURIComponent(url.pathname);
    if (path.length > 1 && path.endsWith("/")) {
      res.writeHead(307, { location: path.replace(/\/+$/, "") + url.search });
      return res.end();
    }
    const base = normalize(join(root, path));
    if (!base.startsWith(root)) {
      res.writeHead(400);
      return res.end();
    }
    const candidates = [base, join(base, "index.html"), `${base}.html`];
    const file = candidates.find(isFile);
    const status = file ? 200 : 404;
    const served = file ?? join(root, "404.html");
    const type = TYPES[extname(served)] ?? "application/octet-stream";
    const compress = /^(text\/|application\/(json|xml)|image\/svg)/.test(type) && /\bbr\b/.test(req.headers["accept-encoding"] ?? "");
    res.writeHead(status, { ...headersFor(rules, file ? path : "/404"), "content-type": type, ...(compress ? { "content-encoding": "br", vary: "accept-encoding" } : {}) });
    const body = createReadStream(served);
    (compress ? body.pipe(createBrotliCompress()) : body).pipe(res);
  });
  return new Promise((ok) => server.listen(port, "127.0.0.1", () => ok(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = await startServer({ port: Number(process.argv[2] ?? 4321), dir: process.argv[3] });
  console.log(`serving ${process.argv[3] ?? OUTPUT_DIR} on http://127.0.0.1:${server.address().port}`);
}
