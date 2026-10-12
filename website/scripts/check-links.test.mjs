// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { checkSite, pagePath } from "./check-links.mjs";

function site(pages) {
  const root = mkdtempSync(join(tmpdir(), "vmpane-links-"));
  for (const [rel, html] of Object.entries(pages)) {
    mkdirSync(join(root, rel, ".."), { recursive: true });
    writeFileSync(join(root, rel), html);
  }
  return root;
}

const page = (body, content = "") => `<html><body>${body}<article class="article" data-docs-article="">${content}</article></body></html>`;

test("served paths have no trailing slash", () => {
  assert.equal(pagePath("/r", "/r/index.html"), "/");
  assert.equal(pagePath("/r", "/r/docs/x/index.html"), "/docs/x");
  assert.equal(pagePath("/r", "/r/404/index.html"), "/404");
});

test("a clean site passes", () => {
  const root = site({
    "index.html": page('<a href="/docs/x">x</a><a href="/docs/x#flags">f</a><a href="https://github.com">gh</a><img src="/logo.svg">'),
    // Served at /docs/x (no trailing slash): "y" is /docs/y and "../" is /.
    "docs/x/index.html": page('<h2 id="flags">Flags</h2><a href="#flags">self</a><a href="y">sibling</a><a href="../">up</a><img srcset="/logo.svg 1x, /a.webp 2x"><div style="background:url(&quot;/a.webp&quot;)"></div>'),
    "docs/y/index.html": page(""),
    "a.webp": "x",
    "docs/index.html": page(""),
    "logo.svg": "<svg/>",
  });
  assert.deepEqual(checkSite(root).problems, []);
  rmSync(root, { recursive: true, force: true });
});

test("prose about handlers or javascript: is not active content", () => {
  const root = site({ "index.html": page("", "<p>Set <code>onload = 1</code> or write javascript: in text.</p>") });
  assert.deepEqual(checkSite(root).problems, []);
  rmSync(root, { recursive: true, force: true });
});

test("a broken link, a missing image candidate, a missing anchor and active content fail", () => {
  const root = site({
    "index.html": page('<a href="/docs/nope">x</a><a href="/docs/x#missing">m</a><img srcset="/gone.webp 2x"><div style="background:url(&quot;/gone2.webp&quot;)"></div>'),
    "docs/x/index.html": page("", '<p>ok</p><img src=x onerror="alert(1)">'),
    "docs/y/index.html": page("", "<script>alert(1)</script>"),
  });
  const { problems } = checkSite(root);
  assert.equal(problems.length, 6, problems.join("\n"));
  assert.ok(problems.some((p) => p.includes("/gone.webp does not exist")));
  assert.ok(problems.some((p) => p.includes("/gone2.webp does not exist")));
  assert.ok(problems.some((p) => p.includes("/docs/nope does not exist")));
  assert.ok(problems.some((p) => p.includes('no element with id "missing"')));
  assert.ok(problems.some((p) => p.startsWith("/docs/x: active content")));
  assert.ok(problems.some((p) => p.startsWith("/docs/y: active content")));
  rmSync(root, { recursive: true, force: true });
});

test("a docs page without the article marker fails (the content checks would pass silently)", () => {
  const root = site({ "docs/index.html": page(""), "docs/x/index.html": '<html><body><article id="nd-page"><script>alert(1)</script></article></body></html>', "index.html": "<html></html>" });
  const { problems } = checkSite(root);
  assert.deepEqual(problems, ["/docs/x: docs page without the data-docs-article marker (the content checks would pass silently)"]);
  rmSync(root, { recursive: true, force: true });
});

test("nothing loads from another origin; outbound links and the canonical URL are fine", () => {
  const ok = site({ "index.html": '<html><head><link rel="canonical" href="https://vmpane.erai.dev/"></head><body><a href="https://github.com/nhtera/vmpane">gh</a></body></html>' });
  assert.deepEqual(checkSite(ok).problems, []);
  rmSync(ok, { recursive: true, force: true });
  const bad = site({
    "index.html":
      '<html><head><link rel="stylesheet" href="https://fonts.googleapis.com/css2?x"><link rel="preconnect" href="//fonts.gstatic.com"><script src="https://cdn.example/x.js"></script></head><body><img srcset="https://img.example/a.webp 2x"><div style="background:url(https://img.example/b.png)"></div></body></html>',
  });
  const { problems } = checkSite(bad);
  for (const u of ["https://fonts.googleapis.com/css2?x", "//fonts.gstatic.com", "https://cdn.example/x.js", "https://img.example/a.webp", "https://img.example/b.png"]) {
    assert.ok(problems.some((p) => p.includes(`loads "${u}"`)), u);
  }
  rmSync(bad, { recursive: true, force: true });
});
