// SPDX-License-Identifier: Apache-2.0

// The npm packages the site ships to browsers or the Worker
// (website/package-lock.json, dev dependencies left out: they build and
// test it) must use an allowed license. No dependencies: CI runs this right
// after `npm ci`.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ALLOWED = ["Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "MPL-2.0", "OFL-1.1", "Unicode-3.0", "CC0-1.0", "0BSD", "Unlicense"];

// Build tools that arrive through runtime packages (the TanStack Start
// Vite plugin, browserslist data). They run at build time and are in no
// bundle: `grep -rl <name> .cloudflare/output` finds nothing.
const BUILD_ONLY = [/^lightningcss(-|$)/, /^argparse$/, /^caniuse-lite$/];

/** An SPDX expression of OR / AND / parentheses over allowed ids (no WITH, no "SEE LICENSE"). */
export function isAllowed(expression) {
  if (typeof expression !== "string" || !expression.trim()) return false;
  const tokens = expression.replace(/[()]/g, " $& ").trim().split(/\s+/);
  let i = 0;
  const atom = () => {
    const t = tokens[i++];
    if (t === "(") {
      const v = or();
      if (tokens[i++] !== ")") throw new Error("unbalanced");
      return v;
    }
    if (!t || [")", "AND", "OR"].includes(t)) throw new Error("syntax");
    return ALLOWED.includes(t);
  };
  const and = () => {
    let v = atom();
    while (tokens[i] === "AND") {
      i++;
      v = atom() && v;
    }
    return v;
  };
  const or = () => {
    let v = and();
    while (tokens[i] === "OR") {
      i++;
      v = and() || v;
    }
    return v;
  };
  try {
    const v = or();
    return i === tokens.length && v;
  } catch {
    return false;
  }
}

export function checkLock(lock) {
  const bad = [];
  let n = 0;
  for (const [path, p] of Object.entries(lock.packages ?? {})) {
    if (path === "" || p.dev) continue;
    const name = path.replace(/^.*node_modules\//, "");
    if (BUILD_ONLY.some((re) => re.test(name))) continue;
    n++;
    if (!isAllowed(p.license)) bad.push(`${name}: license ${p.license ?? "not stated"} is not allowed`);
  }
  return { bad, n };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { bad, n } = checkLock(JSON.parse(readFileSync(new URL("../package-lock.json", import.meta.url), "utf8")));
  if (bad.length) {
    console.error(bad.join("\n"));
    process.exit(1);
  }
  console.log(`npm licenses ok (${n} shipped packages)`);
}
