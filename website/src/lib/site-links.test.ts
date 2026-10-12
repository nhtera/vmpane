// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { docLinkIn, type GeneratedNav } from "./site-links.ts";

const nav: GeneratedNav = {
  index: { title: "Docs", description: "d" },
  sections: [{ title: "Get started", pages: [{ slug: "install", title: "Install", heading: "Install", description: "x", source: "docs/install.md" }] }],
};

test("published pages link to themselves; others fall back", () => {
  assert.equal(docLinkIn(nav, "install"), "/docs/install");
  assert.equal(docLinkIn(nav, "install", { anchor: "models" }), "/docs/install#models");
  assert.equal(docLinkIn(nav, "cli"), "/docs");
  assert.equal(docLinkIn(nav, "security", { fallback: "https://github.com/nhtera/vmpane/blob/main/SECURITY.md" }), "https://github.com/nhtera/vmpane/blob/main/SECURITY.md");
});
