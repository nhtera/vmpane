// SPDX-License-Identifier: Apache-2.0

// The one place site URLs are built. No trailing slash anywhere: the router
// default, and Cloudflare's `drop-trailing-slash` serves /docs/x from
// docs/x/index.html. The links plugin, sitemap, canonical tags and the
// link checker all go through here.

export const SITE_ORIGIN = "https://vmpane.erai.dev";
export const DOCS_BASE = "/docs";
export const REPO_URL = "https://github.com/nhtera/vmpane";
export const REPO_BLOB = `${REPO_URL}/blob/main`;
/** Where VMPane is downloaded: GitHub Releases (a notarized DMG). The one label for it is "Download for Mac". */
export const RELEASES_URL = `${REPO_URL}/releases`;

function anchorPart(anchor?: string): string {
  if (!anchor) return "";
  return anchor.startsWith("#") ? anchor : `#${anchor}`;
}

/** Path of a docs page: `doc("notes", "citations")` → `/docs/notes#citations`. Empty slug → `/docs`. */
export function doc(slug: string, anchor?: string): string {
  const clean = slug.replace(/^\/+|\/+$/g, "");
  return `${clean ? `${DOCS_BASE}/${clean}` : DOCS_BASE}${anchorPart(anchor)}`;
}

/** Absolute URL of a site path, for canonical tags and the sitemap. `/` stays `/`. */
export function absolute(path: string): string {
  if (path === "/" || path === "") return `${SITE_ORIGIN}/`;
  return `${SITE_ORIGIN}${path.replace(/\/+$/, "")}`;
}

/** GitHub URL of a repository file, e.g. `repoFile("SECURITY.md")`. */
export function repoFile(path: string, anchor?: string): string {
  return `${REPO_BLOB}/${path.replace(/^\/+/, "")}${anchorPart(anchor)}`;
}
