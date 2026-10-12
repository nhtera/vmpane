// SPDX-License-Identifier: Apache-2.0

import { resolve } from "node:path";
import { pageSchema } from "fumadocs-core/source/schema";
import { defineConfig, defineDocs } from "fumadocs-mdx/config";
import { z } from "zod";
import { SOURCE_PATH } from "./src/lib/doc-paths.ts";
import { loadNav, publishedSources } from "./src/lib/docs-nav.ts";
import remarkVMPaneLinks from "./src/lib/remark-vmpane-links.ts";
import { vmpaneTheme } from "./src/lib/shiki.ts";

// docs/ (plus the root allowlist) is the source; content/docs is the copy
// `npm run sync` writes. Files are .md, which fumadocs-mdx compiles as
// Markdown (CommonMark + GFM), never MDX: `{…}` is text, not code, and raw
// HTML is not rendered. Paths are relative to website/ (npm scripts and
// Vite run there).
const siteRoot = process.cwd();
const repoRoot = resolve(siteRoot, "..");
const contentDir = resolve(siteRoot, "content/docs");

export const docs = defineDocs({
  dir: "content/docs",
  docs: {
    schema: pageSchema.extend({
      description: z.string().min(1),
      // The repository path the page comes from; the Edit link is built from it.
      source: z.string().regex(SOURCE_PATH),
      lastUpdated: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    }),
  },
});

export default defineConfig({
  mdxOptions: {
    remarkPlugins: (defaults) => [[remarkVMPaneLinks, { repoRoot, contentDir, published: publishedSources(loadNav(repoRoot)) }], ...defaults],
    rehypeCodeOptions: {
      themes: { light: vmpaneTheme, dark: vmpaneTheme },
      // Colours inline as var(--token): one theme, so no dark/light switching.
      defaultColor: "light",
      addLanguageClass: true,
      langs: ["sh", "bash", "json", "yaml", "powershell", "ts", "md"],
    },
  },
});
