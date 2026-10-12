// SPDX-License-Identifier: Apache-2.0

// Paths of docs in the repository (`docs/mcp.md`, `SECURITY.md`), in the
// generated content (`mcp.md`, `security.md`) and on the site
// (`/docs/mcp`, `/docs/security`). Pure functions: the sync script, the
// links plugin and the tests share them. Imports carry the .ts extension so
// Node can run them without a build step.

import { posix } from "node:path";
import { doc, REPO_URL } from "./urls.ts";

/** A doc file name: lowercase letters, digits, `-` and `_`. */
export const DOC_NAME = /^[a-z0-9_-]+\.md$/;

/**
 * Root documents that may be published, linked from docs/README.md as
 * `../NAME.md`. Their slug is the name in lowercase with `-` for `_`
 * (`CODE_OF_CONDUCT.md` → `code-of-conduct`).
 */
export const ROOT_DOCS = ["SECURITY", "CONTRIBUTING", "CODE_OF_CONDUCT"] as const;

/** The one docs folder that may be published (the guest guides). `docs/adr/` and anything else stays on GitHub. */
export const DOC_FOLDERS = ["guides"] as const;

/**
 * Repository paths of docs are validated before they reach a URL: plain
 * segments only, no `..`, and no folder but `docs/guides/`.
 */
export const SOURCE_PATH = /^(?:docs\/(?:guides\/)?(?:[a-z0-9_-]+|README)\.md|(?:SECURITY|CONTRIBUTING|CODE_OF_CONDUCT)\.md)$/;

/** Throws unless every segment of a docs-relative path is a valid name. */
export function checkDocName(rel: string): void {
  const segments = rel.split("/");
  const file = segments.pop() ?? "";
  for (const dir of segments) {
    if (!/^[a-z0-9_-]+$/.test(dir)) throw new Error(`docs/${rel}: folder name "${dir}" must match [a-z0-9_-]+`);
  }
  if (!DOC_NAME.test(file)) throw new Error(`docs/${rel}: file name must match ${DOC_NAME}`);
}

/**
 * The repository path of a docs/README.md link target, or an error message.
 * `overview.md` → `docs/overview.md`; `../SECURITY.md` → `SECURITY.md`.
 * Anything outside docs/ other than the root allowlist, and any folder but
 * docs/guides/, is refused.
 */
export function sourceOfNavHref(href: string): string {
  if (href.startsWith("../")) {
    const name = href.slice(3);
    const root = name.match(/^([A-Z_]+)\.md$/)?.[1];
    if (!root || !(ROOT_DOCS as readonly string[]).includes(root)) {
      throw new Error(`docs/README.md: "${href}" is outside docs/ and not one of ${ROOT_DOCS.map((n) => `../${n}.md`).join(", ")}`);
    }
    return name;
  }
  if (href === "README.md") throw new Error("docs/README.md: README.md is the docs index; it cannot be a nav row");
  const folder = href.includes("/") ? href.slice(0, href.lastIndexOf("/")) : undefined;
  if (folder !== undefined && !(DOC_FOLDERS as readonly string[]).includes(folder)) {
    throw new Error(`docs/README.md: "${href}": only ${DOC_FOLDERS.map((f) => `docs/${f}/`).join(", ")} may be published from a folder`);
  }
  checkDocName(href);
  return `docs/${href}`;
}

/** Site slug of a docs source: `docs/mcp.md` → `mcp`; `CODE_OF_CONDUCT.md` → `code-of-conduct`; `docs/README.md` → ``. */
export function slugOfSource(source: string): string {
  if (!SOURCE_PATH.test(source)) throw new Error(`not a docs source path: ${source}`);
  if (source === "docs/README.md") return "";
  if (!source.startsWith("docs/")) return source.replace(/\.md$/, "").toLowerCase().replaceAll("_", "-");
  return source.slice("docs/".length).replace(/\.md$/, "");
}

/** Where a page lands in content/docs: `mcp.md`, `guides/linux.md`, the index at `index.md`. */
export function contentPathOfSlug(slug: string): string {
  return slug ? `${slug}.md` : "index.md";
}

/** The reverse of contentPathOfSlug. */
export function slugOfContentPath(contentRel: string): string {
  return contentRel === "index.md" ? "" : contentRel.replace(/\.md$/, "");
}

/** GitHub URL of a repository path: `blob` for files, `tree` for folders. */
export function githubUrl(repoPath: string, opts: { anchor?: string; dir?: boolean } = {}): string {
  const clean = repoPath.replace(/^\/+|\/+$/g, "");
  const anchor = opts.anchor ? `#${opts.anchor.replace(/^#/, "")}` : "";
  return `${REPO_URL}/${opts.dir ? "tree" : "blob"}/main/${clean}${anchor}`;
}

/** The "Edit on GitHub" URL of a validated source path. */
export function editUrl(source: string): string {
  if (!SOURCE_PATH.test(source)) throw new Error(`not a docs source path: ${source}`);
  return `${REPO_URL}/edit/main/${source}`;
}

/** Site path of a docs source, with an optional anchor. */
export function docUrlOfSource(source: string, anchor?: string): string {
  return doc(slugOfSource(source), anchor);
}

/** Split `path#anchor` (a URL as written in Markdown). */
export function splitAnchor(url: string): { path: string; anchor?: string } {
  const i = url.indexOf("#");
  if (i < 0) return { path: url };
  return { path: url.slice(0, i), anchor: url.slice(i + 1) || undefined };
}

/** Directory of a repository path, `""` at the root. */
export function repoDir(source: string): string {
  const dir = posix.dirname(source);
  return dir === "." ? "" : dir;
}
