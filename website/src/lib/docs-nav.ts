// SPDX-License-Identifier: Apache-2.0

// What the docs site publishes, and in which order: docs/README.md is the
// nav. Each `## Section` heading is followed by a table whose rows are
// `| [file.md](file.md) | Contents |`; order = sidebar order. Only table rows
// under a `##` heading are read; bullet lists (the repository links) are
// ignored. A file not listed is not published.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { slugOfSource, sourceOfNavHref } from "./doc-paths.ts";

export interface DocEntry {
  /** Repository path: `docs/mcp.md`, `SECURITY.md`. */
  source: string;
  /** Site slug: `mcp`, `security`, `guides/linux`. */
  slug: string;
  /** The Contents cell, as plain text. */
  description: string;
  /** The link text, when it is a label rather than the file name: the page's name in the sidebar. */
  label?: string;
}

export interface NavSection {
  title: string;
  docs: DocEntry[];
}

/** Markdown inline text → plain text: links keep their text, code loses its backticks. */
export function plainText(md: string): string {
  return md
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

const ROW = /^\|\s*\[([^\]]+)\]\(([^)#\s]+)\)\s*\|\s*(.+?)\s*\|\s*$/;

/** Parse docs/README.md into sections. Throws on a refused or duplicate row. */
export function parseNav(md: string): NavSection[] {
  const sections: NavSection[] = [];
  const seen = new Set<string>();
  let current: NavSection | undefined;
  let fence: string | undefined;
  let comment = false;
  for (const line of md.split("\n")) {
    // Rows inside code fences (``` or ~~~) and HTML comments are not published.
    const marker = line.trim().match(/^(`{3,}|~{3,})/)?.[1];
    if (marker && (!fence || marker[0] === fence[0])) {
      fence = fence ? undefined : marker;
      continue;
    }
    if (fence) continue;
    if (comment || line.includes("<!--")) {
      comment = !line.slice(line.lastIndexOf("<!--") >= 0 ? line.lastIndexOf("<!--") : 0).includes("-->");
      continue;
    }
    const heading = line.match(/^##\s+(.+?)\s*#*\s*$/);
    if (heading) {
      current = { title: plainText(heading[1]), docs: [] };
      sections.push(current);
      continue;
    }
    // Any other heading (# or ###) ends the section: rows under it fail.
    if (/^#{1,6}\s/.test(line)) {
      current = undefined;
      continue;
    }
    const row = line.match(ROW);
    if (!row) continue;
    const [, text, href, cell] = row;
    if (!current) throw new Error(`docs/README.md: table row "${href}" is not under a "## Section" heading`);
    const source = sourceOfNavHref(href);
    const slug = slugOfSource(source);
    if (seen.has(source) || seen.has(`slug:${slug}`)) throw new Error(`docs/README.md: ${href} is listed twice (or another row has the slug "${slug}")`);
    seen.add(source);
    seen.add(`slug:${slug}`);
    const description = plainText(cell);
    if (!description) throw new Error(`docs/README.md: ${href} has no description`);
    const label = /\.md$/i.test(text.trim()) ? undefined : plainText(text);
    current.docs.push({ source, slug, description, ...(label ? { label } : {}) });
  }
  const nav = sections.filter((s) => s.docs.length > 0);
  if (nav.length === 0) throw new Error("docs/README.md: no table rows under a ## heading (`| [file.md](file.md) | Contents |`)");
  return nav;
}

/** Read docs/README.md from a repository checkout and build the nav. */
export function loadNav(repoRoot: string): NavSection[] {
  return parseNav(readFileSync(join(repoRoot, "docs", "README.md"), "utf8"));
}

/** Every published source path, plus docs/README.md, which becomes /docs. */
export function publishedSources(nav: NavSection[]): Map<string, string> {
  const out = new Map<string, string>([["docs/README.md", ""]]);
  for (const s of nav) for (const d of s.docs) out.set(d.source, d.slug);
  return out;
}
