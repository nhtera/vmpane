// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { evaluate } from "@mdx-js/mdx";
import { createElement } from "react";
import * as runtime from "react/jsx-runtime";
import { renderToStaticMarkup } from "react-dom/server";
import remarkGfm from "remark-gfm";
import remarkVMPaneLinks, { rewriteUrl, type VMPaneLinksOptions } from "./remark-vmpane-links.ts";

const repoRoot = new URL("../../..", import.meta.url).pathname.replace(/\/$/, "");
const contentDir = `${repoRoot}/website/content/docs`;
const opts: VMPaneLinksOptions = {
  repoRoot,
  contentDir,
  published: new Map([
    ["docs/README.md", ""],
    ["SECURITY.md", "security"],
    ["CONTRIBUTING.md", "contributing"],
    ["test/hostile.md", "hostile"],
  ]),
};

/** Compile Markdown the way the site does (format md + GFM + the plugin) and render it. */
async function render(md: string, contentRel = "contributing.md"): Promise<string> {
  const { default: Content } = await evaluate(
    { value: md, path: `${contentDir}/${contentRel}` },
    { ...runtime, format: "md", remarkPlugins: [[remarkVMPaneLinks, opts], remarkGfm] },
  );
  return renderToStaticMarkup(createElement(Content));
}

test("links resolve from the doc's real location; published docs become site links", () => {
  assert.equal(rewriteUrl("SECURITY.md", "CONTRIBUTING.md", opts), "/docs/security");
  assert.equal(rewriteUrl("SECURITY.md#reporting", "CONTRIBUTING.md", opts), "/docs/security#reporting");
  assert.equal(rewriteUrl("../CONTRIBUTING.md", "docs/README.md", opts), "/docs/contributing");
  assert.equal(rewriteUrl("README.md", "docs/README.md", opts), "/docs");
});

test("links to unpublished docs and repository files go to GitHub", () => {
  assert.equal(rewriteUrl("LICENSE", "CONTRIBUTING.md", opts), "https://github.com/nhtera/vmpane/blob/main/LICENSE");
  assert.equal(rewriteUrl("README.md#install", "CONTRIBUTING.md", opts), "https://github.com/nhtera/vmpane/blob/main/README.md#install");
  assert.equal(rewriteUrl("release.md", "docs/README.md", opts), "https://github.com/nhtera/vmpane/blob/main/docs/release.md");
  assert.equal(rewriteUrl("adr/0002-mcp-sdk.md", "docs/README.md", opts), "https://github.com/nhtera/vmpane/blob/main/docs/adr/0002-mcp-sdk.md");
  assert.equal(rewriteUrl("Packages/", "CONTRIBUTING.md", opts), "https://github.com/nhtera/vmpane/tree/main/Packages");
});

test("anchors and allowed schemes pass; other schemes and missing files fail", () => {
  assert.equal(rewriteUrl("#reporting", "CONTRIBUTING.md", opts), "#reporting");
  assert.equal(rewriteUrl("https://example.com/a", "CONTRIBUTING.md", opts), "https://example.com/a");
  assert.equal(rewriteUrl("mailto:tn@erai.dev", "SECURITY.md", opts), "mailto:tn@erai.dev");
  for (const bad of ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "http://example.com", "//evil.example/x", "vbscript:x"]) {
    assert.throws(() => rewriteUrl(bad, "CONTRIBUTING.md", opts), /only https: and mailto:/, bad);
  }
  assert.throws(() => rewriteUrl("nope.md", "CONTRIBUTING.md", opts), /does not exist/);
  assert.throws(() => rewriteUrl("../../../../etc/passwd", "docs/README.md", opts), /outside the repository/);
  assert.throws(() => rewriteUrl("../x", "CONTRIBUTING.md", opts), /outside the repository/);
});

test("links are rewritten on the tree, never inside code", async () => {
  const html = await render("See [sec](SECURITY.md) and `[x](SECURITY.md)`.\n\n```md\n[y](SECURITY.md)\n```\n\n[ref][r]\n\n[r]: LICENSE\n");
  assert.match(html, /href="\/docs\/security"/);
  assert.match(html, /<code>\[x\]\(SECURITY\.md\)<\/code>/);
  assert.match(html, /\[y\]\(SECURITY\.md\)/);
  assert.match(html, /href="https:\/\/github\.com\/nhtera\/vmpane\/blob\/main\/LICENSE"/);
});

test("the hostile fixture renders inert", async () => {
  const fixture = readFileSync(new URL("../../test/fixtures/hostile.md", import.meta.url), "utf8").replace(/\[javascript link\]\(javascript:alert\(1\)\)\n/, "");
  const html = await render(fixture, "hostile.md");
  assert.match(html, /\{process\.env\.HOME\}/);
  assert.match(html, /\{\{base_url\}\}\/users\/\{\{id\}\}/);
  assert.match(html, /Map&lt;string, number&gt;/);
  for (const bad of ["<script", "onerror", "onclick", "<img", "<div", "a comment"]) assert.ok(!html.includes(bad), bad);
  await assert.rejects(render("[x](javascript:alert(1))", "hostile.md"), /only https: and mailto:/);
});

test("images fail the build", async () => {
  await assert.rejects(render("![logo](logo.png)"), /images are not supported/);
});

test("files outside content/docs are left alone; unknown generated files fail", async () => {
  const { default: Content } = await evaluate({ value: "[x](nope.md)", path: "/elsewhere/page.md" }, { ...runtime, format: "md", remarkPlugins: [[remarkVMPaneLinks, opts]] });
  assert.match(renderToStaticMarkup(createElement(Content)), /href="nope\.md"/);
  await assert.rejects(render("text", "unknown.md"), /not a published doc/);
});
