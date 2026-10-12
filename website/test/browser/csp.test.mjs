// SPDX-License-Identifier: Apache-2.0

// The pages under their production headers: the test server applies the
// build's `_headers` with its own parser (scripts/headers-file.mjs), so a
// script the CSP does not allow (an unhashed inline script, a changed
// hydration payload) shows up here as a violation, and the page must still
// hydrate and work.

import assert from "node:assert/strict";
import { test } from "node:test";
import { siteFixture } from "./helpers.mjs";

const site = siteFixture();

async function open(path) {
  const context = await site.browser.newContext({ reducedMotion: "reduce" });
  await context.addInitScript(() => {
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__cspViolations.push(`${e.violatedDirective} ${e.blockedURI || "inline"} ${e.sample || ""}`));
  });
  const page = await context.newPage();
  const response = await page.goto(site.base + path);
  await page.waitForLoadState("networkidle");
  return { page, context, response };
}

for (const path of ["/", "/docs", "/docs/mcp", "/docs/cli", "/docs/guides/linux", "/nope"]) {
  test(`${path}: served with a CSP, no violation, hydrated`, async () => {
    const { page, context, response } = await open(path);
    const csp = (await response.allHeaders())["content-security-policy"] ?? "";
    assert.match(csp, /script-src 'self'( 'sha256-[A-Za-z0-9+/=]+')+;/);
    assert.ok(!/script-src[^;]*'unsafe-inline'/.test(csp), "no 'unsafe-inline' for scripts");
    assert.equal((await response.allHeaders())["x-frame-options"], "DENY");
    if (path !== "/nope") {
      // Hydrated: the theme toggle works (a React handler, not markup).
      const before = await page.evaluate(() => document.documentElement.dataset.theme);
      await page.locator(".nav .theme-btn").click();
      await page.waitForFunction((b) => document.documentElement.dataset.theme !== b, before);
    }
    assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
    await context.close();
  });
}

test("docs search loads its code and index under the CSP", async () => {
  const { page, context } = await open("/docs");
  await page.keyboard.press("Control+k");
  await page.locator("dialog[open] input").fill("snapshot");
  await page.locator("dialog[open] .results a").first().waitFor();
  assert.deepEqual(await page.evaluate(() => window.__cspViolations), []);
  await context.close();
});
