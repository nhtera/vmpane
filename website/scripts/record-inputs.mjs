// SPDX-License-Identifier: Apache-2.0

// A Vite plugin: adds every file outside website/ that the build reads
// through its module graph to
// content/generated/inputs.json, the list `ci-paths.mjs covers` checks
// against the workflow's SITE_PATHS. The sync step writes the docs inputs;
// this adds the code inputs, so a new import from elsewhere in the
// repository cannot slip past the CI path filter.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { SITE_DIR } from "./paths.mjs";

const REPO = join(SITE_DIR, "..");
const INPUTS = join(SITE_DIR, "content/generated/inputs.json");

/** Repository-relative paths of module ids outside the site and outside node_modules. */
export function outsideInputs(ids, repo = REPO, site = SITE_DIR) {
  const out = new Set();
  for (const raw of ids) {
    const id = raw.split("?")[0];
    if (!id.startsWith(repo) || id.startsWith(site) || id.includes(`${sep}node_modules${sep}`) || id.startsWith("\0")) continue;
    out.add(relative(repo, id).split(sep).join("/"));
  }
  return out;
}

/** Files a CSS file pulls in with relative `@import`s, recursively (Tailwind inlines them, so they never become modules). */
export function cssImports(file, read = (f) => readFileSync(f, "utf8"), found = new Set()) {
  let css;
  try {
    css = read(file);
  } catch {
    return found;
  }
  for (const m of css.matchAll(/@import\s+["'](\.{1,2}\/[^"']+)["']/g)) {
    const target = resolve(dirname(file), m[1]);
    if (found.has(target)) continue;
    found.add(target);
    cssImports(target, read, found);
  }
  return found;
}

export function recordInputs() {
  const seen = new Set();
  return {
    name: "vmpane-record-inputs",
    apply: "build",
    enforce: "pre",
    transform(_code, id) {
      const file = id.split("?")[0];
      if (file.endsWith(".css")) for (const p of outsideInputs(cssImports(file))) seen.add(p);
    },
    buildEnd() {
      for (const p of outsideInputs(this.getModuleIds())) seen.add(p);
    },
    closeBundle() {
      if (!existsSync(INPUTS) || seen.size === 0) return;
      const all = new Set([...JSON.parse(readFileSync(INPUTS, "utf8")), ...seen]);
      writeFileSync(INPUTS, `${JSON.stringify([...all].sort(), null, 2)}\n`);
    },
  };
}
