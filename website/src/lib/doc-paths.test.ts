// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { checkDocName, contentPathOfSlug, docUrlOfSource, editUrl, githubUrl, slugOfContentPath, slugOfSource, sourceOfNavHref, splitAnchor } from "./doc-paths.ts";
import { absolute, doc } from "./urls.ts";

test("slugs: root docs are lowercase with dashes, the index is empty, no trailing slash", () => {
  assert.equal(slugOfSource("docs/mcp.md"), "mcp");
  assert.equal(slugOfSource("docs/guides/linux.md"), "guides/linux");
  assert.equal(slugOfSource("SECURITY.md"), "security");
  assert.equal(slugOfSource("CODE_OF_CONDUCT.md"), "code-of-conduct");
  assert.equal(slugOfSource("docs/README.md"), "");
  assert.equal(docUrlOfSource("SECURITY.md", "reporting"), "/docs/security#reporting");
  assert.equal(doc("x/", "#a"), "/docs/x#a");
  assert.equal(absolute("/docs/x/"), "https://vmpane.erai.dev/docs/x");
  assert.equal(absolute("/"), "https://vmpane.erai.dev/");
});

test("content paths round-trip", () => {
  for (const slug of ["", "mcp", "security", "guides/linux"]) {
    assert.equal(slugOfContentPath(contentPathOfSlug(slug)), slug);
  }
  assert.equal(contentPathOfSlug(""), "index.md");
});

test("nav hrefs: docs pages, docs/guides and the root allowlist only", () => {
  assert.equal(sourceOfNavHref("mcp.md"), "docs/mcp.md");
  assert.equal(sourceOfNavHref("guides/macos.md"), "docs/guides/macos.md");
  for (const root of ["SECURITY", "CONTRIBUTING", "CODE_OF_CONDUCT"]) assert.equal(sourceOfNavHref(`../${root}.md`), `${root}.md`);
  for (const bad of ["../LICENSE", "../README.md", "../CHANGELOG.md", "../NOTICE.md", "../itest/README.md", "../../x.md"]) {
    assert.throws(() => sourceOfNavHref(bad), /outside docs/, bad);
  }
  for (const bad of ["adr/0001-display-path.md", "release/x.md", "guides/deep/x.md"]) {
    assert.throws(() => sourceOfNavHref(bad), /only docs\/guides\//, bad);
  }
  assert.throws(() => sourceOfNavHref("README.md"), /docs index/);
  assert.throws(() => sourceOfNavHref("guides/v1.0.en.md"), /file name/);
  assert.throws(() => sourceOfNavHref("Install.md"), /file name/);
});

test("file names are checked", () => {
  checkDocName("security-model.md");
  checkDocName("guides/linux.md");
  assert.throws(() => checkDocName("Guide.md"), /file name/);
  assert.throws(() => checkDocName("a b.md"), /file name/);
  assert.throws(() => checkDocName("Guides/x.md"), /folder name/);
});

test("GitHub URLs and the edit URL", () => {
  assert.equal(githubUrl("SECURITY.md"), "https://github.com/nhtera/vmpane/blob/main/SECURITY.md");
  assert.equal(githubUrl("README.md", { anchor: "install" }), "https://github.com/nhtera/vmpane/blob/main/README.md#install");
  assert.equal(githubUrl("docs/adr", { dir: true }), "https://github.com/nhtera/vmpane/tree/main/docs/adr");
  assert.equal(editUrl("docs/mcp.md"), "https://github.com/nhtera/vmpane/edit/main/docs/mcp.md");
  assert.equal(editUrl("docs/guides/linux.md"), "https://github.com/nhtera/vmpane/edit/main/docs/guides/linux.md");
  assert.equal(editUrl("CODE_OF_CONDUCT.md"), "https://github.com/nhtera/vmpane/edit/main/CODE_OF_CONDUCT.md");
  for (const bad of ["docs/../../etc/passwd", "docs/../x.md", "docs/./x.md", "https://evil.example/x.md", "LICENSE.md", "docs/adr/0001-display-path.md", "docs/guides/a/b.md"]) {
    assert.throws(() => editUrl(bad), /not a docs source path/, bad);
  }
});

test("anchors split off", () => {
  assert.deepEqual(splitAnchor("x.md#a"), { path: "x.md", anchor: "a" });
  assert.deepEqual(splitAnchor("x.md"), { path: "x.md" });
  assert.deepEqual(splitAnchor("x.md#"), { path: "x.md", anchor: undefined });
});
