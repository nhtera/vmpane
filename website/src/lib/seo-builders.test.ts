// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { faqPage, jsonForScript, softwareApplication } from "./json-ld.ts";
import { llmsTxt } from "./llms.ts";
import type { GeneratedNav } from "./site-links.ts";
import { robotsTxt, sitemapEntries, sitemapXml } from "./sitemap.ts";

const nav: GeneratedNav = {
  index: { title: "VMPane documentation", description: "d" },
  sections: [
    { title: "Get started", pages: [{ slug: "install", title: "Install", heading: "Install", description: "DMG or Homebrew", source: "docs/install.md", lastUpdated: "2026-10-08" }] },
    { title: "Guests", pages: [{ slug: "guides/linux", title: "Linux guests", heading: "Linux guests", description: "Ubuntu, Debian, Fedora", source: "docs/guides/linux.md" }] },
  ],
};

test("the sitemap is the landing page, the docs index and every nav page, no trailing slash", () => {
  assert.deepEqual(
    sitemapEntries(nav).map((e) => e.loc),
    ["https://vmpane.erai.dev/", "https://vmpane.erai.dev/docs", "https://vmpane.erai.dev/docs/install", "https://vmpane.erai.dev/docs/guides/linux"],
  );
  const xml = sitemapXml(nav);
  assert.match(xml, /<loc>https:\/\/vmpane\.erai\.dev\/docs\/install<\/loc><lastmod>2026-10-08<\/lastmod>/);
  assert.ok(!xml.includes("og-card"));
  assert.match(robotsTxt(), /^User-agent: \*\nAllow: \/\n\nSitemap: https:\/\/vmpane\.erai\.dev\/sitemap\.xml\n$/);
});

test("llms.txt lists exactly the nav entries", () => {
  const txt = llmsTxt(nav, { name: "VMPane", summary: "Virtual\nmachines.", details: ["Pre-alpha."] });
  assert.ok(txt.startsWith("# VMPane\n\n> Virtual machines.\n\nPre-alpha.\n\n## Get started\n\n"));
  const links = [...txt.matchAll(/^- \[([^\]]+)\]\(([^)]+)\): (.+)$/gm)].map((m) => m[2]);
  assert.deepEqual(links, ["https://vmpane.erai.dev/docs/install", "https://vmpane.erai.dev/docs/guides/linux"]);
});

test("the built nav and llms.txt agree (when synced)", () => {
  let built: GeneratedNav;
  try {
    built = JSON.parse(readFileSync(new URL("../../content/generated/nav.json", import.meta.url), "utf8"));
  } catch {
    return; // not synced in this checkout
  }
  const txt = llmsTxt(built, { name: "VMPane", summary: "s", details: [] });
  assert.equal([...txt.matchAll(/^- \[/gm)].length, built.sections.flatMap((s) => s.pages).length);
});

test("JSON-LD: FAQPage mirrors the FAQ data; script text cannot close the element", () => {
  const faq = [{ q: "Does it <script> & stuff?", a: "No </script><script>alert(1)</script>" }];
  const page = faqPage(faq);
  assert.equal(page.mainEntity[0].name, faq[0].q);
  assert.equal(page.mainEntity[0].acceptedAnswer.text, faq[0].a);
  const text = jsonForScript([softwareApplication({ name: "VMPane", description: "x" }), page]);
  assert.ok(!text.includes("<") && !text.includes(">") && !text.includes("&"));
  assert.deepEqual(JSON.parse(text)[1], page);
  assert.equal(JSON.parse(text)[0].offers.price, "0");
});
