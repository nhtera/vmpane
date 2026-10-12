// SPDX-License-Identifier: Apache-2.0

// /sitemap.xml: the landing page and every published docs page (the nav),
// canonical URLs only. Pure, so `node --test` runs it.

import type { GeneratedNav } from "./site-links.ts";
import { absolute, doc } from "./urls.ts";

const xmlEscape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export function sitemapEntries(nav: GeneratedNav): { loc: string; lastmod?: string }[] {
  const pages = nav.sections.flatMap((s) => s.pages);
  const newest = pages.map((p) => p.lastUpdated).filter((d): d is string => !!d).sort().at(-1);
  return [
    { loc: absolute("/") },
    { loc: absolute(doc("")), lastmod: newest },
    ...pages.map((p) => ({ loc: absolute(doc(p.slug)), lastmod: p.lastUpdated })),
  ];
}

export function sitemapXml(nav: GeneratedNav): string {
  const urls = sitemapEntries(nav).map((e) => `  <url><loc>${xmlEscape(e.loc)}</loc>${e.lastmod ? `<lastmod>${e.lastmod}</lastmod>` : ""}</url>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`;
}

export function robotsTxt(): string {
  return `User-agent: *\nAllow: /\n\nSitemap: ${absolute("/sitemap.xml")}\n`;
}
