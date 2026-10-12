// SPDX-License-Identifier: Apache-2.0

// Remark plugin for the docs: links written for GitHub become site links,
// and content from a docs pull request cannot inject anything.
//
// - Links resolve from the doc's real location (frontmatter `source`), so a
//   root document (SECURITY.md) and a page in docs/ both work.
// - A link to a published doc → /docs/<slug>#anchor.
// - A link to any other repository file (or a folder) → its GitHub page.
// - `#anchor` stays; https: and mailto: stay; any other scheme fails.
// - A link to a file that does not exist fails, naming the doc and link.
// - Raw HTML (and HTML comments) is dropped; images fail.
// Code is never touched: link nodes do not occur inside code.

import { existsSync, statSync } from "node:fs";
import { posix, relative, sep } from "node:path";
import type { Definition, Link, Nodes, Parent, Root } from "mdast";
import { doc } from "./urls.ts";
import { githubUrl, repoDir, slugOfContentPath, splitAnchor } from "./doc-paths.ts";

export interface VMPaneLinksOptions {
  /** Absolute path of the repository root. */
  repoRoot: string;
  /** Absolute path of the generated content/docs folder. */
  contentDir: string;
  /** Published repository paths → site slug (`SECURITY.md` → `security`). */
  published: Map<string, string>;
}

const ALLOWED_SCHEMES = new Set(["https:", "mailto:"]);

interface VFileLike {
  path?: string;
  history?: string[];
}

/** Rewrite one URL found in the doc whose repository path is `source`. */
export function rewriteUrl(url: string, source: string, opts: VMPaneLinksOptions): string {
  const where = `${source}: link "${url}"`;
  if (url.startsWith("#")) return url;
  const scheme = url.match(/^([a-z][a-z0-9+.-]*):/i)?.[1];
  if (scheme || url.startsWith("//")) {
    if (scheme && ALLOWED_SCHEMES.has(`${scheme.toLowerCase()}:`)) return url;
    throw new Error(`${where}: only https: and mailto: links are allowed`);
  }
  const { path, anchor } = splitAnchor(url);
  if (path === "") return anchor ? `#${anchor}` : url;
  const repoPath = posix.normalize(posix.join(repoDir(source), decodeURI(path)));
  if (repoPath.startsWith("../") || repoPath === ".." || repoPath.startsWith("/")) throw new Error(`${where}: points outside the repository`);
  const abs = `${opts.repoRoot}/${repoPath}`;
  if (!existsSync(abs)) throw new Error(`${where}: ${repoPath} does not exist`);
  const dir = statSync(abs).isDirectory();
  const clean = repoPath.replace(/\/$/, "");
  if (!dir) {
    const slug = opts.published.get(clean);
    if (slug !== undefined) return doc(slug, anchor);
  }
  return githubUrl(clean === "." ? "" : clean, { anchor, dir });
}

function visit(node: Nodes, source: string, opts: VMPaneLinksOptions): void {
  if (!("children" in node)) return;
  const parent = node as Parent;
  for (let i = parent.children.length - 1; i >= 0; i--) {
    const child = parent.children[i] as Nodes;
    switch (child.type) {
      case "html":
        parent.children.splice(i, 1);
        continue;
      case "image":
      case "imageReference":
        throw new Error(`${source}: images are not supported on the site yet`);
      case "link":
      case "definition":
        (child as Link | Definition).url = rewriteUrl((child as Link | Definition).url, source, opts);
        break;
    }
    visit(child, source, opts);
  }
}

/** The repository path of a generated doc, from its place in content/docs (`security.md` → `SECURITY.md`). */
export function sourceOfContentFile(contentFile: string, opts: VMPaneLinksOptions): string {
  const slug = slugOfContentPath(relative(opts.contentDir, contentFile).split(sep).join("/"));
  for (const [source, s] of opts.published) if (s === slug) return source;
  throw new Error(`${contentFile}: not a published doc`);
}

/** Transform a parsed doc whose repository path is `source`. */
export function transformDoc(tree: Root, source: string, opts: VMPaneLinksOptions): void {
  visit(tree, source, opts);
}

export default function remarkVMPaneLinks(opts: VMPaneLinksOptions) {
  return (tree: Root, file: VFileLike) => {
    const path = file.path ?? file.history?.at(-1);
    // Only generated docs are rewritten; anything else compiled with this
    // config is not a repository doc.
    if (!path || !path.startsWith(opts.contentDir)) return;
    transformDoc(tree, sourceOfContentFile(path, opts), opts);
  };
}
