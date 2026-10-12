// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { formatDate, pageContext, parseDocsUrl } from "./docs-toc.ts";
import type { GeneratedNav } from "./site-links.ts";

const page = (slug: string) => ({ slug, title: slug, heading: slug, description: "d", source: `docs/${slug}.md` });
const nav: GeneratedNav = {
  index: { title: "Docs", description: "d" },
  sections: [
    { title: "Get started", pages: [page("install"), page("getting-started")] },
    { title: "Reference", pages: [page("cli")] },
  ],
};

test("previous and next run across sections in nav order", () => {
  assert.deepEqual(pageContext(nav, "install"), { section: "Get started", previous: undefined, next: page("getting-started") });
  const mid = pageContext(nav, "getting-started");
  assert.equal(mid.previous?.slug, "install");
  assert.equal(mid.next?.slug, "cli");
  assert.equal(pageContext(nav, "cli").next, undefined);
});

test("the index and unknown slugs have no context", () => {
  assert.deepEqual(pageContext(nav, ""), {});
  assert.deepEqual(pageContext(nav, "nope"), {});
});

test("dates read like 9 October 2026", () => {
  assert.equal(formatDate("2026-10-09"), "9 October 2026");
  assert.equal(formatDate("2026-01-31"), "31 January 2026");
  assert.equal(formatDate("2026-02-30"), "2026-02-30");
  assert.equal(formatDate("yesterday"), "yesterday");
});

test("docs urls split into a splat and a heading", () => {
  assert.deepEqual(parseDocsUrl("/docs"), { splat: "", hash: undefined });
  assert.deepEqual(parseDocsUrl("/docs/privacy#the-rules"), { splat: "privacy", hash: "the-rules" });
  assert.deepEqual(parseDocsUrl("/docs/release-notes/0-1-0-alpha-1"), { splat: "release-notes/0-1-0-alpha-1", hash: undefined });
  assert.equal(parseDocsUrl("https://example.com/docs/x"), null);
  assert.equal(parseDocsUrl("/documents"), null);
});
