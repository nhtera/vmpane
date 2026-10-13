// SPDX-License-Identifier: Apache-2.0

// The site's text is the system font; the only web font is Caveat, one
// self-hosted face from the site's node_modules, for the agents demo's
// handwritten note (below the fold, so not preloaded).

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
const faces = (css: string) => [...css.matchAll(/@font-face\s*\{[^}]*\}/g)].map((m) => m[0]);

test("fonts.css has one face, Caveat, from node_modules", () => {
  const all = faces(read("./fonts.css"));
  assert.equal(all.length, 1);
  assert.match(all[0], /font-family: 'Caveat'/);
  assert.match(all[0], /url\(\.\.\/\.\.\/node_modules\/@fontsource\/caveat\//);
});

test("no stylesheet reaches for a font host", () => {
  for (const file of ["./fonts.css", "./site.css", "./landing.css", "./docs.css", "./tokens.css"]) {
    assert.doesNotMatch(read(file), /fonts\.(googleapis|gstatic)\.com|@import\s+url\(https?:/, file);
  }
});
