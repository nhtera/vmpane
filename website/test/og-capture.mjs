// SPDX-License-Identifier: Apache-2.0

// Captures the share card: serves the built site, screenshots /og-card at
// 1200×630 (light theme) into public/og.png, and makes the 180 px
// apple-touch-icon from the logo (public/icon.svg) with square corners:
// iOS rounds them itself. Run on demand after `build:site`
// (`npm run og`); both files are committed. Fails if og.png is not
// 1200×630 or is 300 KB or more.

import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright";
import sharp from "sharp";
import { startServer } from "../scripts/serve-dist.mjs";
import { SITE_DIR } from "../scripts/paths.mjs";

const out = join(SITE_DIR, "public/og.png");
const server = await startServer({ port: 0 });
const browser = await chromium.launch();
try {
  const ctx = await browser.newContext({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1, colorScheme: "light", reducedMotion: "reduce" });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/og-card`, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  await page.locator("[data-og-card]").screenshot({ path: out });
} finally {
  await browser.close();
  server.close();
}
const png = await sharp(out).png({ compressionLevel: 9, palette: true, quality: 90 }).toBuffer();
await sharp(png).toFile(out);
const meta = await sharp(out).metadata();
const size = statSync(out).size;
if (meta.width !== 1200 || meta.height !== 630) throw new Error(`og.png is ${meta.width}×${meta.height}, want 1200×630`);
if (size >= 300 * 1024) throw new Error(`og.png is ${Math.round(size / 1024)} KB, want < 300 KB`);
console.log(`public/og.png: 1200×630, ${Math.round(size / 1024)} KB`);

// The icon's outer square (rx 185) and its rim (rx 181) lose their corners.
const square = readFileSync(join(SITE_DIR, "public/icon.svg"), "utf8").replaceAll(' rx="185"', ' rx="0"').replaceAll(' rx="181"', ' rx="0"');
await sharp(Buffer.from(square), { density: 72 }).resize(180, 180).flatten().png({ compressionLevel: 9 }).toFile(join(SITE_DIR, "public/apple-touch-icon.png"));
console.log("public/apple-touch-icon.png: 180×180");
