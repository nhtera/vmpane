// SPDX-License-Identifier: Apache-2.0

// The theme, in a real browser on the built site: data-theme is set before
// first paint from the stored pick, else the OS setting; a bad stored value
// falls back to the OS; the toggle switches and persists; and the token
// variables resolve (body font and background, button radius).

import assert from "node:assert/strict";
import { test } from "node:test";
import { openPage, THEME_KEY, tokenColor, siteFixture } from "./helpers.mjs";

const site = siteFixture();

/** data-theme as the first parsed body element sees it (before any module script runs). */
async function firstPaintTheme(page) {
  return page.evaluate(() => document.documentElement.dataset.theme);
}

for (const [stored, os, want] of [
  ["dark", "light", "dark"],
  ["light", "dark", "light"],
  ["blue", "dark", "dark"],
  [undefined, "dark", "dark"],
  [undefined, "light", "light"],
]) {
  test(`stored ${stored ?? "nothing"}, OS ${os} → ${want}, before hydration`, async () => {
    const ctx = await site.browser.newContext({ colorScheme: os, javaScriptEnabled: true });
    if (stored) await ctx.addInitScript(([k, v]) => localStorage.setItem(k, v), [THEME_KEY, stored]);
    // Block every external script: only the inline head script may set the theme.
    await ctx.route("**/assets/*.js", (r) => r.abort());
    const page = await ctx.newPage();
    await page.goto(`${site.base}/docs`);
    assert.equal(await firstPaintTheme(page), want);
    await ctx.close();
  });
}

test("without JavaScript the page is light", async () => {
  const ctx = await site.browser.newContext({ colorScheme: "dark", javaScriptEnabled: false });
  const page = await ctx.newPage();
  await page.goto(`${site.base}/`);
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme ?? null), null);
  await ctx.close();
});

test("the toggle switches, persists across reload, and labels the next theme", async () => {
  const { page, context } = await openPage(site, "/docs", { colorScheme: "light" });
  const toggle = page.locator(".nav .theme-btn");
  await assert.doesNotReject(toggle.waitFor());
  assert.equal(await toggle.getAttribute("aria-label"), "Switch to dark theme");
  await toggle.click();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
  assert.equal(await toggle.getAttribute("aria-label"), "Switch to light theme");
  assert.equal(await page.evaluate((k) => localStorage.getItem(k), THEME_KEY), "dark");
  await page.reload();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
  await context.close();
});

test("an OS change applies while nothing is stored", async () => {
  const { page, context } = await openPage(site, "/docs", { colorScheme: "light" });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(() => document.documentElement.dataset.theme === "dark");
  await context.close();
});

for (const theme of ["light", "dark"]) {
  test(`${theme}: tokens resolve (background, body font, button radius)`, async () => {
    const { page, context } = await openPage(site, "/", { theme });
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), await tokenColor(page, "--bg", "backgroundColor"));
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).color), await tokenColor(page, "--text"));
    // The system font: SF Pro on Apple devices, no web font for text.
    assert.match(await page.evaluate(() => getComputedStyle(document.body).fontFamily), /^-apple-system, /);
    const radius = await page.evaluate(() => {
      const a = document.createElement("a");
      a.className = "btn";
      document.body.append(a);
      return getComputedStyle(a).borderTopLeftRadius;
    });
    assert.equal(radius, "980px");
    await context.close();
  });
}
