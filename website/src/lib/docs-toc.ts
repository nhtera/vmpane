// SPDX-License-Identifier: Apache-2.0

import type { GeneratedNav, NavPage } from "./site-links";

export interface PageContext {
  /** The section the page is listed under (the crumb). */
  section?: string;
  previous?: NavPage;
  next?: NavPage;
}

/** Section, previous and next page of a slug, in nav order across sections. The index (empty slug) has none. */
export function pageContext(nav: GeneratedNav, slug: string): PageContext {
  const flat = nav.sections.flatMap((s) => s.pages.map((page) => ({ section: s.title, page })));
  const i = flat.findIndex((e) => e.page.slug === slug);
  if (i < 0) return {};
  return { section: flat[i].section, previous: flat[i - 1]?.page, next: flat[i + 1]?.page };
}

/** `2026-10-09` → `9 October 2026`; anything else is returned unchanged. */
export function formatDate(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  if (Number.isNaN(d.getTime()) || d.getUTCDate() !== Number(m[3])) return iso;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
}

/** A `/docs/...#heading` URL as router parts. Null for anything that is not a docs path. */
export function parseDocsUrl(url: string): { splat: string; hash?: string } | null {
  const m = /^\/docs(?:\/([^#?]*))?(?:#(.*))?$/.exec(url);
  if (!m) return null;
  return { splat: (m[1] ?? "").replace(/\/+$/, ""), hash: m[2] || undefined };
}
