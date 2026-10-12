// SPDX-License-Identifier: Apache-2.0

// Every site link to a docs page goes through the published nav
// (content/generated/nav.json, written by `npm run sync` from
// docs/README.md). A page that is not published yet links to /docs, so the
// prerender crawler never follows a link to a missing page.

import navData from "../../content/generated/nav.json" with { type: "json" };
import { doc, repoFile } from "./urls.ts";

export interface NavPage {
  slug: string;
  /** The page's name in the sidebar (the nav row's label, else the H1). */
  title: string;
  /** The page's H1. */
  heading: string;
  description: string;
  source: string;
  /** YYYY-MM-DD of the last commit to the source, when the build has git history. */
  lastUpdated?: string;
}

export interface GeneratedNav {
  index: { title: string; description: string };
  sections: { title: string; pages: NavPage[] }[];
}

export const nav: GeneratedNav = navData;

/** Published slugs of a nav. */
export function publishedSlugs(n: GeneratedNav): Set<string> {
  return new Set(n.sections.flatMap((s) => s.pages.map((p) => p.slug)));
}

/** Link to a docs page if `n` publishes it; else `fallback` (default: the docs index). */
export function docLinkIn(n: GeneratedNav, slug: string, opts: { anchor?: string; fallback?: string } = {}): string {
  return publishedSlugs(n).has(slug) ? doc(slug, opts.anchor) : (opts.fallback ?? doc(""));
}

/** Link to a docs page of this build's nav. */
export function docLink(slug: string, opts: { anchor?: string; fallback?: string } = {}): string {
  return docLinkIn(nav, slug, opts);
}

/** A root document: its docs page when published, else its GitHub page. */
export function rootDocLink(slug: string | undefined, file: string): string {
  return slug ? docLink(slug, { fallback: repoFile(file) }) : repoFile(file);
}
