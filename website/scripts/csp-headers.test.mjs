// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { contentSecurityPolicy, inlineScripts } from "../src/lib/security-headers.ts";
import { buildHeaders, MAX_RULES, requestPath } from "./csp-headers.mjs";
import { staticPage } from "./static-404.mjs";

const NUL = String.fromCharCode(0);
const sha = (t) => createHash("sha256").update(t).digest("base64");

test("inline scripts are read as the browser hashes them", () => {
  const html = `<script>a()</script><script src="/x.js"></script><script type="module" src="/m.js"></script><script data-x="">b("${NUL}")\r\nc()</script><script></script>`;
  assert.deepEqual(inlineScripts(html), ["a()", `b("${String.fromCharCode(0xfffd)}")\nc()`]);
});

test("the CSP allows scripts by hash only", () => {
  const csp = contentSecurityPolicy(["b", "a", "a"]);
  assert.match(csp, /script-src 'self' 'sha256-a' 'sha256-b';/);
  assert.doesNotMatch(csp, /script-src[^;]*unsafe-inline/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.match(csp, /default-src 'self'/);
});

test("_headers has the security headers, immutable assets and one CSP per page", () => {
  const root = mkdtempSync(join(tmpdir(), "vmpane-headers-"));
  mkdirSync(join(root, "docs/x"), { recursive: true });
  writeFileSync(join(root, "index.html"), "<script>one()</script>");
  writeFileSync(join(root, "docs/x/index.html"), "<script>two()</script>");
  writeFileSync(join(root, "404.html"), "<p>x</p>");
  const text = buildHeaders(root);
  assert.match(text, /^\/\*\n {2}Strict-Transport-Security: max-age=31536000; includeSubDomains\n/);
  assert.match(text, /\/assets\/\*\n {2}Cache-Control: public, max-age=31536000, immutable/);
  assert.ok(text.includes(`/\n  Content-Security-Policy: default-src 'self'; script-src 'self' 'sha256-${sha("one()")}'`));
  assert.ok(text.includes(`/docs/x\n  Content-Security-Policy: default-src 'self'; script-src 'self' 'sha256-${sha("two()")}'`));
  assert.match(text, /\/404\n {2}Content-Security-Policy: default-src 'self'; script-src 'self';/);
  for (let i = 0; i < MAX_RULES; i++) writeFileSync(join(root, `p${i}.html`), "");
  assert.throws(() => buildHeaders(root), /Cloudflare reads 100/);
  rmSync(root, { recursive: true, force: true });
});

test("request paths have no trailing slash", () => {
  assert.equal(requestPath("/r", "/r/index.html"), "/");
  assert.equal(requestPath("/r", "/r/docs/x/index.html"), "/docs/x");
  assert.equal(requestPath("/r", "/r/404.html"), "/404");
});

test("the 404 page loses the app bundle and hydration data, keeps the theme scripts", () => {
  const html = '<head><link rel="modulepreload" href="/a.js"/><script>theme()</script></head><body><p>404</p><script>(self.$R=self.$R||{})</script><script data-tsr-stream-part="">self.$_TSR.x</script><script>document.currentScript.remove();/*$tsr-stream-boundary*/</script><script type="module" async="" src="/assets/index.js"></script></body>';
  assert.equal(staticPage(html), "<head><script>theme()</script></head><body><p>404</p></body>");
});
