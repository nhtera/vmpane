// SPDX-License-Identifier: Apache-2.0

// The website's CI path filter, kept in one place: the SITE_PATHS list in
// .github/workflows/site.yml.
//
//   node scripts/ci-paths.mjs match <changed-files.txt>   prints site=true|false
//   node scripts/ci-paths.mjs covers <inputs.json>        fails if a file the
//                                                         build reads is not covered

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const WORKFLOW = fileURLToPath(new URL("../../.github/workflows/site.yml", import.meta.url));

/**
 * The SITE_PATHS globs from the workflow: the indented lines of the
 * `SITE_PATHS: |` block. No dependencies, so CI runs this before any install.
 */
export function sitePaths(workflowText = readFileSync(WORKFLOW, "utf8")) {
  const lines = workflowText.split("\n");
  const start = lines.findIndex((l) => /^\s+SITE_PATHS: \|\s*$/.test(l));
  if (start < 0) throw new Error("site.yml: env.SITE_PATHS missing");
  const indent = lines[start].match(/^\s*/)[0].length;
  const out = [];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === "") continue;
    if (line.match(/^\s*/)[0].length <= indent) break;
    if (!line.trim().startsWith("#")) out.push(line.trim());
  }
  if (out.length === 0) throw new Error("site.yml: env.SITE_PATHS is empty");
  return out;
}

/** `dir/**` matches anything under dir; anything else matches exactly. */
export function matches(path, globs) {
  return globs.some((g) => (g.endsWith("/**") ? path.startsWith(g.slice(0, -2)) : path === g));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, file] = process.argv.slice(2);
  const globs = sitePaths();
  if (mode === "match") {
    const changed = readFileSync(file, "utf8").split("\n").filter(Boolean);
    console.log(`site=${changed.some((p) => matches(p, globs))}`);
  } else if (mode === "covers") {
    const missing = JSON.parse(readFileSync(file, "utf8")).filter((p) => !matches(p, globs));
    if (missing.length) {
      console.error(`files the site build reads but .github/workflows/site.yml SITE_PATHS does not cover:\n  ${missing.join("\n  ")}`);
      process.exit(1);
    }
    console.log("site inputs covered by the CI path filter");
  } else {
    console.error("usage: ci-paths.mjs match <changed.txt> | covers <inputs.json>");
    process.exit(2);
  }
}
