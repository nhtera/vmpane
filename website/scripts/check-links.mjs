// SPDX-License-Identifier: Apache-2.0

// Checks the built site as it will be deployed (OUTPUT_DIR by default):
// every internal href, src, srcset candidate and CSS url() resolves to a
// file (`/x` → x/index.html), every anchor names an element id on its page,
// nothing is loaded from another origin (no third-party subresource: scripts,
// styles, fonts, images, frames), and the docs content (the element marked
// `data-docs-article`, which every /docs page must have) carries no <script>,
// <iframe>, on*= handler or javascript: URL.
//
//   node scripts/check-links.mjs [dir]

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { OUTPUT_DIR } from "./paths.mjs";

const decode = (s) => s.replace(/&amp;/g, "&").replace(/&#x27;/g, "'").replace(/&quot;/g, '"');

function htmlFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...htmlFiles(p));
    else if (e.name.endsWith(".html")) out.push(p);
  }
  return out;
}

/** The URL path a file is served at: docs/x/index.html → /docs/x. */
export function pagePath(root, file) {
  const rel = relative(root, file).split(sep).join("/");
  const path = `/${rel.replace(/(^|\/)index\.html$/, "").replace(/\.html$/, "")}`;
  return path.length > 1 ? path.replace(/\/$/, "") : "/";
}

/** The file a site path is served from, or undefined. */
export function resolveFile(root, path) {
  const base = join(root, decodeURIComponent(path));
  for (const c of [base, join(base, "index.html"), `${base}.html`]) {
    if (existsSync(c) && statSync(c).isFile()) return c;
  }
  return undefined;
}

const ids = (html) => new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => decode(m[1])));

/** The docs content of a page: the <article data-docs-article> element, or null when the page has none. */
export function docsContent(html) {
  const m = html.match(/<article\b[^>]*\sdata-docs-article\b[^>]*>/);
  if (!m) return null;
  const start = m.index;
  const end = html.indexOf("</article>", start);
  return html.slice(start, end < 0 ? undefined : end);
}

/**
 * URLs on other origins that a page would load (not links): src and srcset
 * of any tag, href of <link> other than canonical/alternate, CSS url(),
 * and poster/data attributes.
 */
export function thirdPartyLoads(html) {
  const out = [];
  const external = (u) => /^(https?:)?\/\//i.test(u.trim());
  for (const m of html.matchAll(/<([a-z][a-z0-9-]*)\b([^>]*)>/gi)) {
    const [, tag, attrs] = m;
    for (const a of attrs.matchAll(/\s(src|poster|data)="([^"]*)"/gi)) if (external(decode(a[2]))) out.push(decode(a[2]));
    for (const a of attrs.matchAll(/\s(?:srcset|imagesrcset)="([^"]*)"/gi)) {
      for (const part of decode(a[1]).split(",")) {
        const url = part.trim().split(/\s+/)[0];
        if (url && external(url)) out.push(url);
      }
    }
    if (tag.toLowerCase() === "link" && !/\srel="(canonical|alternate)"/i.test(attrs)) {
      const href = attrs.match(/\shref="([^"]*)"/i)?.[1];
      if (href && external(decode(href))) out.push(decode(href));
    }
  }
  for (const m of decode(html).matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)) if (external(m[1])) out.push(m[1]);
  return out;
}

/** Every URL a page loads or links to: href, src, each srcset candidate, and CSS url(). */
export function references(html) {
  const out = [];
  for (const m of html.matchAll(/\s(href|src)="([^"]*)"/g)) out.push(decode(m[2]));
  for (const m of html.matchAll(/\s(?:srcset|imageSrcSet)="([^"]*)"/gi)) {
    for (const part of decode(m[1]).split(",")) {
      const url = part.trim().split(/\s+/)[0];
      if (url) out.push(url);
    }
  }
  for (const m of decode(html).matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)) out.push(m[1]);
  return out.filter((u) => u !== "");
}

/** Problems in one built site directory, as strings. */
export function checkSite(root) {
  const problems = [];
  const files = htmlFiles(root);
  const idCache = new Map();
  const idsOf = (file) => {
    if (!idCache.has(file)) idCache.set(file, ids(readFileSync(file, "utf8")));
    return idCache.get(file);
  };
  for (const file of files) {
    const html = readFileSync(file, "utf8");
    const from = pagePath(root, file);
    // Active content inside the docs article: script or iframe tags, on*
    // attributes, javascript: URLs in attributes. Text is not matched, so a
    // doc may mention `onload =` or javascript: in prose or code.
    const content = docsContent(html);
    if (content === null && (from === "/docs" || from.startsWith("/docs/"))) {
      problems.push(`${from}: docs page without the data-docs-article marker (the content checks would pass silently)`);
    }
    for (const url of thirdPartyLoads(html)) problems.push(`${from}: loads "${url}" from another origin`);
    const tags = (content ?? "").match(/<[a-z][^>]*>/gi) ?? [];
    if (tags.some((t) => /^<(script|iframe)\b/i.test(t) || /\son[a-z]+\s*=/i.test(t) || /=\s*["']?\s*javascript:/i.test(t))) {
      problems.push(`${from}: active content (script, iframe, on*= or javascript:) inside the docs content`);
    }
    for (const url of references(html)) {
      if (/^(https?:|mailto:|data:)/i.test(url)) continue;
      if (/^javascript:/i.test(url)) {
        problems.push(`${from}: javascript: URL`);
        continue;
      }
      // The page is served at `from` with no trailing slash, so relative URLs
      // resolve the way a browser resolves them there.
      const target = new URL(url, `http://site${from}`);
      const path = target.pathname.length > 1 ? target.pathname.replace(/\/$/, "") : "/";
      const targetFile = resolveFile(root, path);
      if (!targetFile) {
        problems.push(`${from}: "${url}" → ${path} does not exist`);
        continue;
      }
      const anchor = decodeURIComponent(target.hash.slice(1));
      if (anchor && targetFile.endsWith(".html") && !idsOf(targetFile).has(anchor)) {
        problems.push(`${from}: "${url}" → no element with id "${anchor}" on ${path}`);
      }
    }
  }
  return { problems, pages: files.length };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = resolve(process.argv[2] ?? OUTPUT_DIR);
  const { problems, pages } = checkSite(root);
  if (problems.length) {
    console.error(`check-links: ${problems.length} problem(s) in ${root}:\n  ${problems.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`links ok (${pages} pages in ${relative(process.cwd(), root) || "."})`);
}
