// SPDX-License-Identifier: Apache-2.0

import type { SortedResult } from "fumadocs-core/search";
import { parseDocsUrl } from "./docs-toc.ts";

export interface Segment {
  text: string;
  mark: boolean;
}

/**
 * The search index marks matches with `<mark>…</mark>` inside otherwise plain
 * text. Only those two tags are understood; everything else (including any
 * other `<`) is literal text, so a result can never carry markup into the page.
 */
export function highlightSegments(content: string): Segment[] {
  const out: Segment[] = [];
  let mark = false;
  for (const part of content.split(/(<\/?mark>)/)) {
    if (part === "<mark>") mark = true;
    else if (part === "</mark>") mark = false;
    else if (part) out.push({ text: part, mark });
  }
  return out;
}

export interface ResultHit {
  id: string;
  url: string;
  type: SortedResult["type"];
  content: string;
}

export interface ResultGroup {
  id: string;
  /** Page url without the heading. */
  url: string;
  /** Page title (may carry highlight marks). */
  title: string;
  /** Section the page belongs to. */
  section?: string;
  hits: ResultHit[];
}

/** Group a flat result list by page, keeping the index's order. Results that are not docs urls are dropped. */
export function groupResults(results: SortedResult[]): ResultGroup[] {
  const groups = new Map<string, ResultGroup>();
  for (const r of results) {
    const parts = parseDocsUrl(r.url);
    if (!parts) continue;
    const pageUrl = parts.splat ? `/docs/${parts.splat}` : "/docs";
    let g = groups.get(pageUrl);
    if (!g) {
      g = { id: `search-group-${groups.size}`, url: pageUrl, title: "", hits: [] };
      groups.set(pageUrl, g);
    }
    if (r.type === "page") {
      g.title = r.content;
      g.section = r.breadcrumbs?.at(-1);
    } else {
      g.hits.push({ id: r.id, url: r.url, type: r.type, content: r.content });
    }
  }
  return [...groups.values()].filter((g) => g.title || g.hits.length > 0);
}
