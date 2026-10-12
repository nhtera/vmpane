// SPDX-License-Identifier: Apache-2.0

// Shared setup for the browser suites: serve the built site (as Cloudflare
// would: drop-trailing-slash, 404.html with status 404) and open pages in
// Chromium with a theme, viewport and pointer. Needs `npm run build:site`
// and a Chromium (npx playwright install chromium).
// BASE_URL=https://vmpane.erai.dev runs a suite against production instead.

import { after, before } from "node:test";
import { chromium } from "playwright";
import { startServer } from "../../scripts/serve-dist.mjs";

export const THEME_KEY = "vmpane-site-theme";

export function siteFixture() {
  const ctx = { base: process.env.BASE_URL?.replace(/\/$/, ""), browser: undefined, server: undefined };
  before(async () => {
    if (!ctx.base) {
      ctx.server = await startServer();
      ctx.base = `http://127.0.0.1:${ctx.server.address().port}`;
    }
    ctx.browser = await chromium.launch();
  });
  after(async () => {
    await ctx.browser?.close();
    ctx.server?.close();
  });
  return ctx;
}

/**
 * A fresh page. `theme`: stored theme ("light" | "dark" | any string to
 * store as is) or undefined (follow the OS, `colorScheme`). `touch`: a
 * coarse pointer (mobile emulation).
 */
export async function openPage(site, path, { width = 1280, height = 900, theme, colorScheme = "light", reducedMotion = "reduce", touch = false, storage = {}, wait = true } = {}) {
  const context = await site.browser.newContext({ viewport: { width, height }, colorScheme, reducedMotion, hasTouch: touch, isMobile: touch });
  const init = { ...storage, ...(theme === undefined ? {} : { [THEME_KEY]: theme }) };
  if (Object.keys(init).length) {
    await context.addInitScript((entries) => {
      for (const [k, v] of Object.entries(entries)) localStorage.setItem(k, v);
    }, init);
  }
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => {
    if (m.type() === "error" && !/status of 404/.test(m.text())) errors.push(m.text());
  });
  await page.goto(site.base + path);
  if (wait) await page.waitForLoadState("networkidle");
  return { page, context, errors };
}

/** The computed color of a CSS variable in this page (for comparisons). */
export function tokenColor(page, name, prop = "color") {
  return page.evaluate(
    ([n, p]) => {
      const probe = document.createElement("div");
      probe.style[p] = `var(${n})`;
      document.body.append(probe);
      const c = getComputedStyle(probe)[p];
      probe.remove();
      return c;
    },
    [name, prop],
  );
}
