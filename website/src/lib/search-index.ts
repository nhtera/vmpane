// SPDX-License-Identifier: Apache-2.0

import type { StructuredData } from "fumadocs-core/mdx-plugins/remark-structure";
import { createFromSource } from "fumadocs-core/search/server";
import type { LoaderConfig, LoaderOutput } from "fumadocs-core/source";

// The search index is one static file the browser downloads on first search.
// Indexing every paragraph costs about 11x the Markdown's size, so the build
// uses the fullest level that stays under the budget: all text, then titles,
// headings and the first paragraph of each section, then titles and headings.
// The first level that fits is used; none fitting fails the build.
// The budget is on the gzip size, close to what is transferred (Cloudflare
// serves brotli, smaller still): the JSON compresses about 4-7x.

export const INDEX_BUDGET = 250_000;

/** Gzip size of a text, with the Web Streams API (Node and workerd alike). */
export async function gzipSize(text: string): Promise<number> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return (await new Response(stream).arrayBuffer()).byteLength;
}

export type IndexLevel = "full" | "lead" | "headings";
export const INDEX_LEVELS: IndexLevel[] = ["full", "lead", "headings"];

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

/**
 * The structured text keeps some Markdown (`**bold**`, `code`, `\{`, `\<`, `&#x20;`).
 * Results show it as plain text, so drop the syntax and undo the escapes: the characters come
 * back as characters, which React then renders as text like any other.
 */
export function tidyText(text: string): string {
  return text
    .replace(/&#x([0-9a-f]+);|&#(\d+);|&([a-z]+);/gi, (m, hex, dec, name) => {
      const cp = hex ? parseInt(hex, 16) : dec ? Number(dec) : undefined;
      if (cp !== undefined) return cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
      return NAMED[String(name).toLowerCase()] ?? m;
    })
    .replace(/\*\*(.+?)\*\*|`([^`\n]+)`/g, (_m, bold, code) => bold ?? code)
    .replace(/\\([!-/:-@[-`{-~])/g, "$1")
    .trim();
}

export function trimStructuredData(data: StructuredData, level: IndexLevel): StructuredData {
  const headings = data.headings.map((h) => ({ ...h, content: tidyText(h.content) }));
  if (level === "headings") return { headings, contents: [] };
  // "lead": the first paragraph of each section only.
  const seen = new Set<string | undefined>();
  const kept = data.contents.filter((c) => {
    if (level === "full") return true;
    const first = !seen.has(c.heading);
    seen.add(c.heading);
    return first;
  });
  return { headings, contents: kept.map((c) => ({ ...c, content: tidyText(c.content) })) };
}

interface PageLike {
  data: { title?: string; description?: string; structuredData?: unknown; load?: () => Promise<{ structuredData: StructuredData }> };
  url: string;
  path: string;
}

async function structuredDataOf(page: PageLike): Promise<StructuredData> {
  const sd = page.data.structuredData;
  const data = typeof sd === "function" ? await sd() : sd ? sd : (await page.data.load?.())?.structuredData;
  if (!data) throw new Error(`${page.path}: no structured data to index`);
  return data as StructuredData;
}

/** The search index as JSON text, at the fullest level within `budget` gzipped bytes. */
export async function buildSearchIndex<C extends LoaderConfig>(source: LoaderOutput<C>, budget = INDEX_BUDGET): Promise<{ level: IndexLevel; json: string }> {
  for (const level of INDEX_LEVELS) {
    const server = createFromSource(source, {
      language: "english",
      buildIndex: async (page) => ({
        title: page.data.title ?? page.path,
        description: page.data.description,
        url: page.url,
        id: page.url,
        structuredData: trimStructuredData(await structuredDataOf(page as unknown as PageLike), level),
      }),
    });
    const json = JSON.stringify(await server.export());
    if ((await gzipSize(json)) <= budget) return { level, json };
  }
  throw new Error(`search index is over ${budget} gzipped bytes even with titles and headings only`);
}
