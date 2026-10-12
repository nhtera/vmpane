// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { SortedResult } from "fumadocs-core/search";
import { structure } from "fumadocs-core/mdx-plugins/remark-structure";
import { groupResults, highlightSegments } from "./search-text.ts";

test("only <mark> becomes a highlight; other markup stays text", () => {
  assert.deepEqual(highlightSegments("a <mark>Plaud</mark> b <script>x</script> <img onerror=x>"), [
    { text: "a ", mark: false },
    { text: "Plaud", mark: true },
    { text: " b <script>x</script> <img onerror=x>", mark: false },
  ]);
  assert.deepEqual(highlightSegments(""), []);
});

const r = (over: Partial<SortedResult>): SortedResult => ({ id: "i", url: "/docs/a", type: "text", content: "c", ...over });

test("results are grouped by page in index order", () => {
  const groups = groupResults([
    r({ id: "1", url: "/docs/a", type: "page", content: "A page", breadcrumbs: ["Docs", "Guides"] }),
    r({ id: "2", url: "/docs/a#h", type: "heading", content: "Heading" }),
    r({ id: "3", url: "/docs/a", type: "text", content: "body" }),
    r({ id: "4", url: "/docs/b/c", type: "page", content: "B page", breadcrumbs: ["Docs"] }),
    r({ id: "5", url: "https://evil.example/", type: "page", content: "off site" }),
  ]);
  assert.equal(groups.length, 2);
  assert.deepEqual([groups[0].title, groups[0].section, groups[0].url, groups[0].hits.map((h) => h.url)], ["A page", "Guides", "/docs/a", ["/docs/a#h", "/docs/a"]]);
  assert.equal(groups[1].url, "/docs/b/c");
});

// The hostile fixture goes through the index builder the build uses: nothing
// that runs (script, event handlers, javascript: targets) reaches the index,
// and whatever markup-looking text does is shown as text by highlightSegments.
test("the hostile fixture indexes as inert text", () => {
  const body = readFileSync(new URL("../../test/fixtures/hostile.md", import.meta.url), "utf8");
  const text = JSON.stringify(structure(body));
  assert.doesNotMatch(text, /<script|onerror|onclick|alert\(1\)|javascript:/i);
  const generic = structure(body).contents.find((c) => c.content.includes("angle brackets"));
  assert.ok(generic);
  assert.deepEqual(highlightSegments(generic.content).filter((s) => s.mark), []);
});
