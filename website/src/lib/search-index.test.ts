// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { structure } from "fumadocs-core/mdx-plugins/remark-structure";
import { staticClient } from "fumadocs-core/search/client/orama-static";
import { buildSearchIndex, gzipSize, tidyText, trimStructuredData } from "./search-index.ts";

const md = `
## One

First paragraph of one with zebra.

Second paragraph of one with giraffe.

## Two

First of two.

Second of two with okapi.
`;

test("levels keep the headings and thin the text", () => {
  const sd = structure(md);
  assert.deepEqual(trimStructuredData(sd, "full").contents, sd.contents);
  const lead = trimStructuredData(sd, "lead");
  assert.deepEqual(lead.contents.map((c) => c.content), ["First paragraph of one with zebra.", "First of two."]);
  assert.deepEqual(lead.headings, sd.headings);
  assert.deepEqual(trimStructuredData(sd, "headings").contents, []);
});

test("markdown escapes in the structured text are undone", () => {
  assert.equal(tidyText("Map\\<string, number> and&#x20;"), "Map<string, number> and");
  assert.equal(tidyText("\\{\\{base_url}}/users &amp; &lt;b&gt; &#65; &bogus;"), "{{base_url}}/users & <b> A &bogus;");
  assert.equal(tidyText("**Download models** Pick `Light` or `Max`."), "Download models Pick Light or Max.");
  assert.equal(tidyText("plain text, 3 * 4"), "plain text, 3 * 4");
});

const page = (slug: string, text: string) => ({
  url: `/docs/${slug}`,
  path: `${slug}.md`,
  data: { title: slug, description: `About ${slug}`, structuredData: structure(text) },
});
const source = (pages: ReturnType<typeof page>[]) => ({ getPages: () => pages, getPageTree: () => ({ name: "Docs", children: [] }) }) as never;

// Query the exported index the way the browser does: staticClient over fetch.
let n = 0;
async function hits(json: string, query: string) {
  const real = globalThis.fetch;
  globalThis.fetch = (async () => new Response(json)) as typeof fetch;
  try {
    return await staticClient({ from: `http://index.test/${n++}.json` }).search(query);
  } finally {
    globalThis.fetch = real;
  }
}

test("the full index finds a word that only appears in a body paragraph", async () => {
  const { level, json } = await buildSearchIndex(source([page("a", md)]));
  assert.equal(level, "full");
  const found = await hits(json, "giraffe");
  assert.ok(found.some((r) => r.type === "text" && r.url === "/docs/a#one"), JSON.stringify(found));
});

test("a small budget falls back to thinner levels, then fails", async () => {
  const s = source([page("a", md)]);
  const full = await gzipSize((await buildSearchIndex(s)).json);
  const lead = await buildSearchIndex(s, full - 1);
  assert.equal(lead.level, "lead");
  assert.equal((await hits(lead.json, "giraffe")).length, 0);
  assert.ok((await hits(lead.json, "zebra")).length > 0);
  await assert.rejects(buildSearchIndex(s, 10), /over 10 gzipped bytes/);
});
