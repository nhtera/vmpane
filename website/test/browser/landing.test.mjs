// SPDX-License-Identifier: Apache-2.0

// The landing page on the built site: complete without JavaScript, the
// phone menu (opens without moving the page; closes on a link, a tap outside
// or Esc, which returns focus to the button), and privacy: every request
// goes to the site itself and no cookie is set.

import assert from "node:assert/strict";
import { test } from "node:test";
import { openPage, siteFixture } from "./helpers.mjs";

const site = siteFixture();

test("the page is complete without JavaScript", async () => {
  const ctx = await site.browser.newContext({ javaScriptEnabled: false });
  const page = await ctx.newPage();
  await page.goto(`${site.base}/`);
  const text = await page.locator("main").innerText();
  for (const s of ["Three systems.", "One Mac.", "Download for Mac", "Common questions."]) assert.ok(text.includes(s), s);
  assert.equal(await page.locator("h1").count(), 1);
  assert.ok((await page.locator(".faq details").count()) >= 6);
  assert.equal(await page.locator('meta[name="viewport"]').count(), 1);
  await ctx.close();
});

test("phone menu: opens without moving the page, closes on Esc, a tap outside and a link", async () => {
  const { page, context, errors } = await openPage(site, "/", { width: 390, height: 844, touch: true });
  const button = page.locator(".nav .menu-btn");
  const links = page.locator("#navlinks");
  // A tap where the element is on screen: locator.tap() would first scroll the
  // sticky header to its place in the document.
  const tapOn = async (locator) => {
    const b = await locator.boundingBox();
    await page.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2);
  };
  assert.equal(await links.isVisible(), false);
  await page.evaluate(() => window.scrollTo(0, 400));
  const y = await page.evaluate(() => window.scrollY);
  await tapOn(button);
  assert.equal(await button.getAttribute("aria-expanded"), "true");
  assert.ok(await links.isVisible());
  assert.equal(await page.evaluate(() => window.scrollY), y);

  await page.keyboard.press("Escape");
  assert.equal(await links.isVisible(), false);
  assert.equal(await page.evaluate(() => document.activeElement?.classList.contains("menu-btn")), true);

  await tapOn(button);
  // A tap on the page below the menu card.
  await page.touchscreen.tap(195, 820);
  assert.equal(await links.isVisible(), false);

  await tapOn(button);
  await tapOn(links.getByRole("link", { name: "FAQ" }));
  assert.equal(await links.isVisible(), false);
  await page.waitForFunction(() => location.hash === "#faq");
  // The section lands below the floating nav.
  await page.waitForFunction(() => {
    const top = document.getElementById("faq").getBoundingClientRect().top;
    return top >= document.querySelector(".nav-in").getBoundingClientRect().bottom - 1 && top < 120;
  });
  assert.deepEqual(errors, []);
  await context.close();
});

test("privacy: every request goes to the site itself, and no cookie is set", async () => {
  const ctx = await site.browser.newContext({ reducedMotion: "no-preference" });
  const page = await ctx.newPage();
  const origin = new URL(site.base).origin;
  const foreign = [];
  const cookies = [];
  page.on("request", (r) => {
    const u = new URL(r.url());
    if (u.protocol !== "data:" && u.origin !== origin) foreign.push(r.url());
  });
  page.on("response", async (r) => {
    const h = await r.allHeaders();
    if (h["set-cookie"]) cookies.push(r.url());
  });
  for (const path of ["/", "/docs", "/docs/mcp", "/nope"]) {
    await page.goto(site.base + path);
    await page.waitForLoadState("networkidle");
  }
  assert.deepEqual(foreign, []);
  assert.deepEqual(cookies, []);
  assert.equal(await page.evaluate(() => document.cookie), "");
  assert.deepEqual(await ctx.cookies(), []);
  await ctx.close();
});

test("phone menu by keyboard: Tab reaches the button, Enter opens, Esc closes and refocuses it", async () => {
  const { page, context } = await openPage(site, "/", { width: 390, height: 844 });
  const button = page.locator(".nav .menu-btn");
  for (let i = 0; i < 6 && !(await button.evaluate((b) => b === document.activeElement)); i++) await page.keyboard.press("Tab");
  assert.equal(await button.evaluate((b) => b === document.activeElement), true, "Tab reaches the menu button");
  await page.keyboard.press("Enter");
  assert.ok(await page.locator("#navlinks").isVisible());
  await page.keyboard.press("Tab");
  assert.equal(await page.evaluate(() => document.activeElement?.closest("#navlinks") !== null), true, "focus moves into the open menu");
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("#navlinks").isVisible(), false);
  assert.equal(await button.evaluate((b) => b === document.activeElement), true);
  await context.close();
});

test("Reduce Transparency: no element keeps a backdrop blur, and the glass is solid", async () => {
  for (const path of ["/", "/docs/mcp"]) {
    const { page, context } = await openPage(site, path);
    const cdp = await context.newCDPSession(page);
    await cdp.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-transparency", value: "reduce" }] });
    assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-transparency: reduce)").matches), true);
    const blurred = await page.evaluate(() =>
      [...document.querySelectorAll("*")].filter((el) => {
        const s = getComputedStyle(el);
        return (s.backdropFilter && s.backdropFilter !== "none") || (s.webkitBackdropFilter && s.webkitBackdropFilter !== "none");
      }).map((el) => el.className || el.tagName),
    );
    assert.deepEqual(blurred, [], path);
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--glass").trim()), "100%");
    await context.close();
  }
});

test("phone without JavaScript: no menu button, the links are a row in the header", async () => {
  const ctx = await site.browser.newContext({ javaScriptEnabled: false, viewport: { width: 375, height: 812 } });
  const page = await ctx.newPage();
  await page.goto(`${site.base}/`);
  assert.equal(await page.locator(".nav .menu-btn").isVisible(), false);
  for (const name of ["Features", "AI agents", "FAQ", "Docs", "GitHub"]) assert.ok(await page.locator("#navlinks").getByRole("link", { name }).isVisible(), name);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await ctx.close();
});

test("phone menu: the theme switch is its last row, and Tab out of the menu closes it", async () => {
  const { page, context } = await openPage(site, "/", { width: 390, height: 844 });
  assert.equal(await page.locator(".nav-in > .theme-btn").isVisible(), false);
  await page.locator(".nav .menu-btn").focus();
  await page.keyboard.press("Enter");
  const row = page.locator("#navlinks .nav-theme");
  assert.ok(await row.isVisible());
  const before = await page.evaluate(() => document.documentElement.dataset.theme);
  await row.click();
  assert.notEqual(await page.evaluate(() => document.documentElement.dataset.theme), before);
  await row.focus();
  await page.keyboard.press("Tab");
  assert.equal(await page.locator("#navlinks").isVisible(), false);
  await context.close();
});
