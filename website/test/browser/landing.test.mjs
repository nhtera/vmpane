// SPDX-License-Identifier: Apache-2.0

// The landing page on the built site: complete without JavaScript; the
// phone menu (opens without moving the page; closes on a link, a tap outside
// or Esc, which returns focus to the button); the story's end state with
// reduced motion; the guest tabs, level chips and carousel by keyboard; the
// Windows timeline; the handwritten font; no sideways scrolling at any
// width; and privacy: every request goes to the site itself, no cookie.

import assert from "node:assert/strict";
import { test } from "node:test";
import { openPage, siteFixture } from "./helpers.mjs";

const site = siteFixture();

test("the page is complete without JavaScript", async () => {
  const ctx = await site.browser.newContext({ javaScriptEnabled: false });
  const page = await ctx.newPage();
  await page.goto(`${site.base}/`);
  const text = await page.locator("main").innerText();
  for (const s of ["Three systems.", "One Mac.", "Download for Mac", "Every VM is a Mac app.", "Nothing runs until you say so.", "Set up Windows.", "One switch stops every agent.", "What VMPane", "Common questions.", "brew install --cask nhtera/tap/vmpane"]) assert.ok(text.includes(s), s);
  // VMPane's windows are drawn in HTML: each picture says what it shows.
  // (the ones a screen reader can reach: not in a hidden tab or the decorative collage)
  const pictures = await page
    .locator("main [role=img]")
    .evaluateAll((els) => els.filter((el) => !el.closest("[hidden], [aria-hidden=true]")).map((el) => el.getAttribute("aria-label") ?? ""));
  assert.ok(pictures.length >= 10, `${pictures.length} pictures`);
  for (const label of pictures) assert.ok(label.length > 10, label);
  assert.equal(await page.locator("main img:not([alt])").count(), 0);
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

test("the glass blurs: the header pill, the story's menu bar, Dock and dialog, the menu (the unprefixed property survives the build)", async () => {
  const { page, context } = await openPage(site, "/");
  const filters = await page.evaluate(() => [".nav-in", ".story .menubar", ".story .dock", ".story .alert", ".cell .menu"].map((sel) => getComputedStyle(document.querySelector(sel)).backdropFilter));
  for (const f of filters) assert.match(f, /blur\(/);
  await context.close();
});

test("Reduce Transparency: no element keeps a backdrop blur, and the glass is solid", async () => {
  for (const path of ["/", "/docs/mcp"]) {
    const { page, context } = await openPage(site, path);
    const cdp = await context.newCDPSession(page);
    await cdp.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-transparency", value: "reduce" }] });
    assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-transparency: reduce)").matches), true);
    // Chromium restyles elements inside a size container (the Mac's screen) a frame after an emulated media change.
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
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

test("reduced motion: the story is its final frame, all four steps in view", async () => {
  const { page, context } = await openPage(site, "/", { width: 1440, height: 900, reducedMotion: "reduce" });
  await page.locator("#story").scrollIntoViewIfNeeded();
  const steps = page.locator("#story .steps li");
  assert.equal(await steps.count(), 4);
  for (const li of await steps.all()) {
    assert.ok(await li.isVisible());
    assert.equal(await li.evaluate((el) => getComputedStyle(el).opacity), "1");
  }
  for (const sel of [".s-lib", ".s-vm", ".s-alert", ".s-typed"]) {
    assert.equal(await page.locator(`#story ${sel}`).evaluate((el) => getComputedStyle(el).opacity), "1", sel);
  }
  // Not pinned: the section is as tall as its content.
  assert.ok((await page.locator("#story").evaluate((el) => el.getBoundingClientRect().height)) < 2000);
  await context.close();
});

test("motion allowed: the story pins under the nav while its beats play", async () => {
  const { page, context } = await openPage(site, "/", { width: 1440, height: 900, reducedMotion: "no-preference" });
  const supported = await page.evaluate(() => CSS.supports("animation-timeline: view()"));
  if (!supported) return context.close();
  const story = page.locator("#story");
  const top = await story.evaluate((el) => el.getBoundingClientRect().top + scrollY);
  const height = await story.evaluate((el) => el.getBoundingClientRect().height);
  assert.ok(height > 2.5 * 900, `story is ${height}px tall`);
  await page.evaluate((y) => scrollTo(0, y), top + height / 2);
  await page.waitForTimeout(200);
  const stageTop = await page.locator("#story .story-stage").evaluate((el) => el.getBoundingClientRect().top);
  const pin = await page.evaluate(() => parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--pin-top")));
  assert.ok(Math.abs(stageTop - pin) <= 1, `stage at ${stageTop}, pin ${pin}`);
  await context.close();
});

test("motion allowed: the pinned stage holds the Mac, the caption and the bar at every size, so nothing spills onto the next section", async () => {
  for (const [width, height] of [[1440, 900], [1280, 720], [1024, 768], [1920, 1080], [390, 844], [390, 664]]) {
    const { page, context } = await openPage(site, "/", { width, height, reducedMotion: "no-preference" });
    if (!(await page.evaluate(() => CSS.supports("animation-timeline: view()")))) return context.close();
    const spill = await page.evaluate(() => {
      const stage = document.querySelector("#story .story-stage");
      const bottom = Math.max(...[...stage.children].map((c) => c.getBoundingClientRect().bottom));
      return bottom - stage.getBoundingClientRect().bottom;
    });
    assert.ok(spill <= 0, `${width}x${height}: the stage's content runs ${spill}px past it`);
    await context.close();
  }
});

test("guest tabs: click and arrow keys move selection and focus; one panel and one window shown", async () => {
  const { page, context } = await openPage(site, "/");
  const tabs = page.locator('#guests [role="tab"]');
  assert.equal(await tabs.count(), 3);
  await tabs.nth(1).click();
  assert.equal(await tabs.nth(1).getAttribute("aria-selected"), "true");
  await page.keyboard.press("ArrowRight");
  assert.equal(await tabs.nth(2).getAttribute("aria-selected"), "true");
  assert.equal(await page.evaluate(() => document.activeElement?.id), "t-win");
  await page.keyboard.press("ArrowRight");
  assert.equal(await tabs.first().getAttribute("aria-selected"), "true");
  await page.keyboard.press("End");
  assert.equal(await tabs.nth(2).getAttribute("aria-selected"), "true");
  assert.deepEqual(await tabs.evaluateAll((ts) => ts.map((t) => t.tabIndex)), [-1, -1, 0]);
  assert.equal(await page.locator('#guests [role="tabpanel"]:not([hidden])').count(), 1);
  assert.equal(await page.locator('#guests [role="tabpanel"]:not([hidden]) h3').textContent(), "Windows 11 on Arm, set up for you.");
  assert.equal(await page.locator("#guests .media:not([hidden])").count(), 1);
  await context.close();
});

test("level chips set the drawn Settings, the app's explanation and the activity the session leaves", async () => {
  const { page, context } = await openPage(site, "/");
  const chips = page.locator('#agents .lvls button');
  assert.equal(await chips.count(), 5);
  assert.equal(await chips.nth(3).getAttribute("aria-pressed"), "true");
  assert.match(await page.locator("#agents .explain").textContent(), /run commands as the logged-in user/);
  await chips.first().focus();
  await page.keyboard.press("Enter");
  assert.equal(await chips.first().getAttribute("aria-pressed"), "true");
  assert.equal(await page.locator("#agents .explain").textContent(), "Off. Agents cannot see this VM.");
  assert.equal(await page.locator("#agents .explain").getAttribute("aria-live"), "polite");
  assert.equal(await page.locator("#agents .popup").textContent(), "Off");
  assert.equal(await page.locator("#agents .act").innerText(), "No agent has used this VM.");
  // Run commands: the administrator command is refused with the policy's own reason.
  await chips.nth(3).click();
  assert.match(await page.locator("#agents .act").innerText(), /agent\.exec needs policy level admin; this VM allows exec/);
  // Full control: it reaches the person, who says no.
  await chips.nth(4).click();
  assert.equal(await page.locator("#agents .popup").textContent(), "Full control");
  assert.match(await page.locator("#agents .act").innerText(), /the person at this Mac did not allow it/);
  await context.close();
});

test("carousel: Next and Previous step through and turn off at the ends", async () => {
  const { page, context } = await openPage(site, "/", { width: 1280 });
  const prev = page.getByRole("button", { name: "Previous feature" });
  const next = page.getByRole("button", { name: "Next feature" });
  assert.equal(await prev.isDisabled(), true);
  const track = page.locator(".track");
  await next.click();
  await page.waitForFunction(() => document.querySelector(".track").scrollLeft > 100);
  // The buttons follow the scroll on the next frame.
  await assert.doesNotReject(prev.waitFor({ state: "attached" }).then(() => page.waitForFunction(() => !document.querySelector('[aria-label="Previous feature"]').disabled)));
  for (let i = 0; i < 8 && !(await next.isDisabled()); i++) {
    await next.click();
    await page.waitForTimeout(150);
  }
  await page.waitForFunction(() => document.querySelector('[aria-label="Next feature"]').disabled);
  assert.equal(await track.getAttribute("tabindex"), "0");
  await context.close();
});

test("the Windows timeline fills when it comes into view (motion allowed), and is full with reduced motion", async () => {
  const moving = await openPage(site, "/", { reducedMotion: "no-preference" });
  const timeline = moving.page.locator(".timeline");
  assert.match(await timeline.getAttribute("class"), /armed/);
  await timeline.scrollIntoViewIfNeeded();
  await moving.page.waitForFunction(() => document.querySelector(".timeline").classList.contains("run"));
  await moving.context.close();
  const still = await openPage(site, "/", { reducedMotion: "reduce" });
  assert.doesNotMatch(await still.page.locator(".timeline").getAttribute("class"), /armed/);
  assert.equal(await still.page.locator(".timeline .tstep").first().evaluate((el) => getComputedStyle(el).opacity), "1");
  await still.context.close();
});

test("the hero's stickers sit inside it, so its clipped edges never cut one", async () => {
  for (const width of [1100, 1440, 1920]) {
    const { page, context } = await openPage(site, "/", { width, height: 900 });
    const outside = await page.evaluate(() => {
      const hero = document.querySelector(".hero").getBoundingClientRect();
      return [...document.querySelectorAll(".hero .st")]
        .filter((s) => { const r = s.getBoundingClientRect(); return r.left < hero.left || r.right > hero.right || r.top < hero.top || r.bottom > hero.bottom - 8; })
        .map((s) => s.getAttribute("src") || s.outerHTML.slice(0, 60));
    });
    assert.deepEqual(outside, [], `${width}px`);
    await context.close();
  }
});

test("the handwritten note's font loads from the site", async () => {
  const { page, context } = await openPage(site, "/");
  await page.evaluate(() => document.fonts.ready);
  assert.ok(await page.evaluate(() => document.fonts.check('600 26px "Caveat"')));
  assert.equal(await page.locator(".demo-hand .hand").evaluate((el) => getComputedStyle(el).fontFamily.split(",")[0].replaceAll('"', "")), "Caveat");
  await context.close();
});

test("no sideways scrolling on the landing page from 320 to 1440 px, light and dark", async () => {
  const wide = [];
  for (const theme of ["light", "dark"]) {
    for (const width of [320, 375, 390, 768, 1024, 1440]) {
      const { page, context } = await openPage(site, "/", { width, height: 800, theme, touch: width < 800, reducedMotion: "no-preference" });
      for (const y of [0, 1500, 4000, 9000]) {
        await page.evaluate((top) => scrollTo(0, top), y);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        if (overflow > 0) wide.push(`${theme} ${width}px at ${y}: ${overflow}px`);
      }
      await context.close();
    }
  }
  assert.deepEqual(wide, []);
});
