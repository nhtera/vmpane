// SPDX-License-Identifier: Apache-2.0

// The site's logo (public/icon.svg) is the app icon's master,
// Config/AppIcon.svg, cropped to its rounded square: the same gradients and
// shapes, no outer drop shadow. A change to the app icon fails here until
// the site's copy follows.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
/** Gradients and shapes, without the icon's outer shadow. */
const parts = (svg: string) =>
  [...svg.matchAll(/<(?:linearGradient|radialGradient|rect|path|circle)\b[^>]*>/g)].map((m) => m[0].replace(' filter="url(#icon-shadow)"', ""));

test("public/icon.svg is Config/AppIcon.svg cropped to the icon's square", () => {
  const master = read("../../../Config/AppIcon.svg");
  const site = read("../../public/icon.svg");
  assert.deepEqual(parts(site), parts(master));
  assert.match(site, /viewBox="100 100 824 824"/);
  assert.doesNotMatch(site, /icon-shadow/);
});
