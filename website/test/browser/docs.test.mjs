// SPDX-License-Identifier: Apache-2.0

// The docs in a browser, on the built site: layout, search from the static
// index, client navigation without a server, keyboard, narrow screens and
// accessibility. The pages come from the published nav, so this test follows
// whatever docs/README.md publishes. Needs `npm run build:site` and Chromium.

import AxeBuilder from "@axe-core/playwright";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, test } from "node:test";
import { chromium } from "playwright";
import { startServer } from "../../scripts/serve-dist.mjs";

const nav = JSON.parse(readFileSync(new URL("../../content/generated/nav.json", import.meta.url), "utf8"));
const pages = nav.sections.flatMap((s) => s.pages.map((p) => ({ ...p, section: s.title })));
const docMd = (slug) => readFileSync(new URL(`../../content/docs/${slug}.md`, import.meta.url), "utf8");

let server, browser, base;
before(async () => {
  server = await startServer();
  base = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch();
});
after(async () => {
  await browser?.close();
  server?.close();
});

async function open(path, { width = 1280, height = 900, theme = "light" } = {}) {
  const context = await browser.newContext({ viewport: { width, height }, colorScheme: theme });
  await context.addInitScript((t) => localStorage.setItem("vmpane-site-theme", t), theme);
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => m.type() === "error" && problems.push(`console: ${m.text()}`));
  page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  await page.goto(`${base}${path}`);
  await page.waitForLoadState("networkidle");
  return { page, context, problems };
}

async function eventually(fn, what, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.fail(`not met in time: ${what}`);
}

// A word from a page's first body paragraph that no title, description or
// other page contains: searching it must find that page, and only it.
function uniqueBodyWord() {
  const all = Object.fromEntries(pages.map((p) => [p.slug, docMd(p.slug)]));
  for (const p of pages) {
    const body = all[p.slug].replace(/^---[\s\S]*?\n---\n/, "");
    const para = body.split(/\n\s*\n/).find((b) => /^[A-Za-z]/.test(b) && !b.startsWith("|"));
    for (const word of para?.match(/\b[a-z]{7,}\b/g) ?? []) {
      const others = pages.filter((q) => q.slug !== p.slug).map((q) => all[q.slug]);
      const inMeta = `${p.title} ${p.description} ${nav.index.title} ${nav.index.description}`.toLowerCase().includes(word);
      if (!inMeta && !others.some((t) => t.toLowerCase().includes(word))) return { word, page: p };
    }
  }
  return null;
}

test("/docs lists every section and page from the nav", async () => {
  const { page, context, problems } = await open("/docs");
  await page.locator("article[data-docs-article] h1").waitFor();
  assert.equal(await page.locator("article h1").textContent(), nav.index.title);
  assert.deepEqual(await page.locator("article h2").allTextContents(), nav.sections.map((s) => s.title));
  const cards = await page.locator("article .cards a").evaluateAll((as) => as.map((a) => [a.getAttribute("href"), a.querySelector("strong").textContent, a.querySelector("span").textContent]));
  assert.deepEqual(cards, pages.map((p) => [`/docs/${p.slug}`, p.title, p.description]));
  assert.deepEqual(problems, []);
  await context.close();
});

test("every nav page renders with the sidebar in nav order", async () => {
  for (const p of pages) {
    const { page, context, problems } = await open(`/docs/${p.slug}`);
    assert.equal(await page.locator("article[data-docs-article] h1").textContent(), p.heading, p.slug);
    assert.equal(await page.locator("article .crumb").textContent(), p.section, p.slug);
    assert.equal(await page.locator("article .lead").textContent(), p.description, p.slug);
    const links = await page.locator("aside.docs-side .nav-group a").evaluateAll((as) => as.map((a) => [a.getAttribute("href"), a.getAttribute("aria-current")]));
    assert.deepEqual(links.map((l) => l[0]), pages.map((q) => `/docs/${q.slug}`), p.slug);
    assert.deepEqual(links.filter((l) => l[1] === "page").map((l) => l[0]), [`/docs/${p.slug}`], p.slug);
    assert.deepEqual(problems, [], p.slug);
    await context.close();
  }
});

test("the pager runs across the nav order", async () => {
  for (const [i, p] of pages.entries()) {
    const { page, context } = await open(`/docs/${p.slug}`);
    const prev = await page.locator(".pager .prev").getAttribute("href").catch(() => null);
    const next = await page.locator(".pager .next").getAttribute("href").catch(() => null);
    assert.equal(prev, i > 0 ? `/docs/${pages[i - 1].slug}` : null, p.slug);
    assert.equal(next, i < pages.length - 1 ? `/docs/${pages[i + 1].slug}` : null, p.slug);
    await context.close();
  }
});

test("a page links to its source on GitHub and shows when it changed", async () => {
  const p = pages[0];
  const { page, context } = await open(`/docs/${p.slug}`);
  assert.equal(await page.getByRole("link", { name: "Edit this page on GitHub" }).getAttribute("href"), `https://github.com/nhtera/vmpane/edit/main/${p.source}`);
  // Every page has a date unless the build was told to skip them (shallow clones).
  if (!process.env.VMPANE_SITE_NO_DATES) {
    for (const q of pages) {
      assert.match(q.lastUpdated ?? "", /^\d{4}-\d{2}-\d{2}$/, `${q.slug}: no lastUpdated in nav.json`);
    }
    const updated = page.locator(".edit time");
    assert.equal(await updated.getAttribute("datetime"), p.lastUpdated);
    assert.match(await updated.textContent(), /^\d{1,2} [A-Z][a-z]+ \d{4}$/);
  }
  await context.close();
});

test("Ctrl+K opens search on docs pages, Esc closes it and focus returns to the trigger", async () => {
  const { page, context } = await open(`/docs/${pages[0].slug}`);
  await page.getByRole("button", { name: "Search docs" }).first().focus();
  await page.keyboard.press("Enter");
  const dialog = page.getByRole("dialog", { name: "Search docs" });
  await dialog.waitFor();
  await eventually(async () => (await page.evaluate(() => document.activeElement?.id)) === "search-input", "input focused");
  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "hidden" });
  assert.equal(await page.evaluate(() => document.activeElement?.className), "search-btn");
  await page.keyboard.press("Control+k");
  await dialog.waitFor();
  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "hidden" });
  await context.close();
});

test("the shortcut does nothing outside the docs", async () => {
  const { page, context } = await open("/");
  await page.keyboard.press("Control+k");
  assert.equal(await page.locator("dialog.search").count(), 0);
  await context.close();
});

test("search finds a word that only appears in a page body and opens that page at its heading", async () => {
  const found = uniqueBodyWord();
  assert.ok(found, "the published docs have no word unique to one page body");
  const { page, context, problems } = await open("/docs");
  const requests = [];
  page.on("request", (r) => requests.push(new URL(r.url()).pathname));
  assert.ok(!requests.includes("/api/search.json"));
  await page.keyboard.press("Control+k");
  await page.getByRole("dialog").waitFor();
  await page.keyboard.type(found.word);
  const options = page.getByRole("dialog").getByRole("option");
  await eventually(async () => (await options.count()) > 0, "results");
  assert.ok(requests.includes("/api/search.json"), "the index is downloaded on first open");
  const first = await options.first().getAttribute("href");
  assert.equal(first, `/docs/${found.page.slug}`);
  assert.equal(await options.first().getAttribute("aria-selected"), "true");
  // Highlighted as text: a <mark> with the word, no markup from content.
  assert.match((await page.locator("dialog .results mark").first().textContent()).toLowerCase(), new RegExp(found.word.slice(0, 5)));
  await page.keyboard.press("ArrowDown");
  const second = await options.nth(1).getAttribute("href");
  assert.equal(await options.nth(1).getAttribute("aria-selected"), "true");
  assert.equal(await page.locator("#search-input").getAttribute("aria-activedescendant"), await options.nth(1).getAttribute("id"));
  await page.keyboard.press("Enter");
  await page.waitForURL((u) => u.pathname === `/docs/${found.page.slug}`);
  assert.equal(await page.locator("dialog.search").evaluate((d) => d.open), false);
  if (second.includes("#")) assert.equal(new URL(page.url()).hash, `#${second.split("#")[1]}`);
  assert.deepEqual(problems, []);
  await context.close();
});

test("search with no match shows the empty state", async () => {
  const { page, context } = await open("/docs");
  await page.keyboard.press("Control+k");
  await page.keyboard.type("qqzzxxyy");
  await page.locator(".search-note", { hasText: "No page matches “qqzzxxyy”. Try a shorter word." }).waitFor();
  assert.equal(await page.getByRole("dialog").getByRole("option").count(), 0);
  await context.close();
});

test("search results carry no markup from the content", async () => {
  const { page, context } = await open("/docs");
  await page.keyboard.press("Control+k");
  await page.keyboard.type(uniqueBodyWord().word);
  await eventually(async () => (await page.locator("dialog .results a").count()) > 0, "results");
  const markup = await page.locator("dialog .results").evaluate((el) => [...el.querySelectorAll("*")].map((e) => e.tagName.toLowerCase()).filter((t) => !["div", "a", "span", "small", "mark"].includes(t)));
  assert.deepEqual(markup, []);
  await context.close();
});

test("client navigation reads the static docs index, never a server function", async () => {
  const { page, context } = await open("/docs");
  const requests = [];
  page.on("request", (r) => requests.push(new URL(r.url()).pathname));
  // Same-origin static files only: anything else fails the page.
  await page.route("**/*", (route) => (new URL(route.request().url()).origin === base ? route.continue() : route.abort()));
  const target = pages[pages.length - 1];
  await page.locator(`aside.docs-side a[href="/docs/${target.slug}"]`).click();
  await page.waitForURL(`**/docs/${target.slug}`);
  await page.getByRole("heading", { level: 1, name: target.heading }).waitFor();
  assert.deepEqual(requests.filter((p) => !p.startsWith("/assets/")), ["/api/docs-tree.json"]);
  assert.equal(await page.evaluate(() => document.activeElement?.tagName), "H1");
  await context.close();
});

test("the table of contents marks the section in view", async () => {
  for (const p of pages) {
    const { page, context } = await open(`/docs/${p.slug}`, { height: 500 });
    const links = page.locator(".toc a");
    if ((await links.count()) < 2) {
      await context.close();
      continue;
    }
    const last = links.last();
    await last.click();
    // The page scrolls smoothly: wait for the end of the scroll, not the first heading it passes.
    const want = await last.getAttribute("href");
    await eventually(async () => (await page.locator('.toc a[aria-current="true"]').evaluateAll((as) => as.map((a) => a.getAttribute("href")))).join() === want, `${p.slug}: ${want} is the one active heading`);
    await context.close();
    return;
  }
});

for (const width of [375, 768]) {
  test(`no horizontal scroll at ${width}px, and the docs menu replaces the sidebar`, async () => {
    for (const path of ["/docs", ...pages.map((p) => `/docs/${p.slug}`)]) {
      const { page, context } = await open(path, { width });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      assert.ok(overflow <= 0, `${path}: ${overflow}px wider than the viewport`);
      assert.equal(await page.locator("aside.docs-side").isVisible(), false);
      assert.equal(await page.locator(".toc").isVisible().catch(() => false), false);
      await page.getByText("Docs menu").click();
      assert.ok(await page.locator(".docs-menu .search-btn").isVisible());
      await context.close();
    }
  });
}

test("on a wide screen the sidebar and the table of contents are shown", async () => {
  const { page, context } = await open(`/docs/${pages[0].slug}`, { width: 1440 });
  assert.ok(await page.locator("aside.docs-side").isVisible());
  assert.equal(await page.locator(".docs-menu").isVisible(), false);
  await context.close();
});

for (const theme of ["light", "dark"]) {
  test(`no accessibility violations in the ${theme} theme (docs, page, search)`, async () => {
    const audit = async (page, what) => {
      const { violations } = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
      assert.deepEqual(violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(" ")).join(", ")}`), [], what);
    };
    for (const path of ["/docs", ...pages.map((p) => `/docs/${p.slug}`)]) {
      const { page, context } = await open(path, { theme });
      await audit(page, path);
      if (path === "/docs") {
        await page.keyboard.press("Control+k");
        await page.keyboard.type(uniqueBodyWord().word);
        await eventually(async () => (await page.locator("dialog .results a").count()) > 0, "results");
        await audit(page, `${path} search open`);
      }
      await context.close();
    }
  });
}

test("scrolling code and tables are focusable named groups, and Copy is a button", async () => {
  for (const p of pages) {
    const { page, context } = await open(`/docs/${p.slug}`);
    for (const el of await page.locator(".table-scroll, .code pre").all()) {
      assert.equal(await el.getAttribute("role"), "group", p.slug);
      assert.ok(await el.getAttribute("aria-label"), p.slug);
      assert.equal(await el.getAttribute("tabindex"), "0", p.slug);
    }
    for (const b of await page.locator(".code .copy-btn").all()) assert.equal(await b.evaluate((e) => e.tagName), "BUTTON");
    await context.close();
  }
});
