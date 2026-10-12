// SPDX-License-Identifier: Apache-2.0

// Fails when the site lockfile (or the one given, e.g. deploy/package-lock.json)
// has a package with an install script that is not on the allowlist. Dependencies are installed with
// `npm ci --ignore-scripts`, so a new install script never runs; this makes
// one visible in review before anyone relies on it.

import { readFileSync } from "node:fs";

// Packages whose install scripts are known. None is needed: each ships its
// platform binary as an optional dependency, which npm installs without
// running scripts.
// Matched by package name wherever npm nests it (the Cloudflare tools pin
// their own workerd).
const allowed = new Set([
  "esbuild", // checks its platform binary
  "fsevents", // optional macOS file watcher; ships prebuilt
  "workerd", // checks its platform binary
]);

const lockPath = process.argv[2] ? new URL(process.argv[2], `file://${process.cwd()}/`) : new URL("../package-lock.json", import.meta.url);
const lock = JSON.parse(readFileSync(lockPath, "utf8"));
const unexpected = Object.entries(lock.packages ?? {})
  .filter(([path, pkg]) => pkg.hasInstallScript && !allowed.has(path.replace(/^.*node_modules\//, "")))
  .map(([path]) => path);

if (unexpected.length > 0) {
  console.error(`install scripts not on the allowlist in ${lockPath.pathname} (site/scripts/check-install-scripts.mjs):\n  ${unexpected.join("\n  ")}`);
  process.exit(1);
}
console.log("install scripts ok");
