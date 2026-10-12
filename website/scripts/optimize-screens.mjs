// SPDX-License-Identifier: Apache-2.0

// Turns the app screenshots of the gated marketing specs (apps/desktop and
// apps/mobile `tests/e2e/marketing.spec.ts`, see README "Screenshots") into the
// site's images: public/screens/<id>-<theme>-<width>.<hash>.webp at two widths
// each, and the manifest src/content/screens.json the landing page reads:
//   { "<id>": { width, height, light: [{ w, src }], dark: [{ w, src }] } }
// (largest width first). The hash is the content's (first 8 hex of its sha256).
//
// A recapture must not churn binaries in the public repo, so a WebP is
// rewritten only when its decoded image visibly changed against the file the
// manifest already names (see `changed`); otherwise the old file and manifest
// entry stay and two runs on the same shots change nothing. Fails when the
// images together take more than the budget. Files in public/screens that the
// manifest no longer names are removed.

import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import sharp from "sharp";

/** The shots, in manifest order: the size the spec captures and the widths served. */
export const SHOTS = [
  { id: "desk-live", width: 2800, height: 1602, widths: [2800, 1400] },
  { id: "desk-notes", width: 2800, height: 1602, widths: [2800, 1400] },
  { id: "phone-live", width: 1179, height: 2556, widths: [1179, 590] },
  { id: "phone-meetings", width: 1179, height: 2556, widths: [1179, 590] },
];
export const THEMES = ["light", "dark"];
/** WebP quality; sharp's smartSubsample keeps the colour of thin text (4:4:4-like chroma). */
export const WEBP = { quality: 86, effort: 6, smartSubsample: true };
export const BUDGET_BYTES = 2.5 * 1024 * 1024;
/** A pixel counts as changed when a channel moves by more than this (0-255) ... */
export const PIXEL_DELTA = 12;
/** ... and the image as changed when more than this share of its pixels did. */
export const CHANGED_SHARE = 0.0005;

/** `<id>-<theme>-<w>.<hash8>.webp` */
export const fileName = (id, theme, w, hash) => `${id}-${theme}-${w}.${hash}.webp`;

/** The first 8 hex of the sha256 of the bytes. */
export const contentHash = (buf) => createHash("sha256").update(buf).digest("hex").slice(0, 8);

/** True when `name` is a file this script produces (the only kind it ever removes). */
export const isScreenFile = (name) => /^[a-z0-9-]+-(light|dark)-\d+\.[0-9a-f]{8}\.webp$/.test(name);

/** Share of pixels whose channels differ by more than `delta` between two same-size raw buffers. */
export function changedShare(a, b, delta = PIXEL_DELTA) {
  if (a.length !== b.length) return 1;
  let n = 0;
  for (let i = 0; i < a.length; i += 3) {
    if (Math.abs(a[i] - b[i]) > delta || Math.abs(a[i + 1] - b[i + 1]) > delta || Math.abs(a[i + 2] - b[i + 2]) > delta) n++;
  }
  return n / (a.length / 3);
}

/** Rewrite the file? Yes when there is none, the size differs, or the image visibly changed. */
export function changed(prev, next) {
  if (!prev) return true;
  if (prev.width !== next.width || prev.height !== next.height) return true;
  return changedShare(prev.raw, next.raw) > CHANGED_SHARE;
}

/** `items`: [{ id, theme, w, src }] -> the manifest object (shots in SHOTS order, widths largest first). */
export function buildManifest(items) {
  const manifest = {};
  for (const s of SHOTS) {
    const entry = { width: s.width, height: s.height };
    for (const theme of THEMES) {
      entry[theme] = items
        .filter((i) => i.id === s.id && i.theme === theme)
        .sort((x, y) => y.w - x.w)
        .map((i) => ({ w: i.w, src: i.src }));
    }
    manifest[s.id] = entry;
  }
  return manifest;
}

/** Throws when the images take more than the budget. */
export function checkBudget(total, budget = BUDGET_BYTES) {
  if (total > budget) throw new Error(`the images take ${total} bytes, over the ${budget} budget: lower WEBP.quality`);
}

const rawOf = async (input) => {
  const { data, info } = await sharp(input).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  return { raw: data, width: info.width, height: info.height };
};

async function main() {
  const site = join(dirname(fileURLToPath(import.meta.url)), "..");
  const shots = process.env.GHI_MARKETING_OUT ?? join(site, ".screens");
  const outDir = join(site, "public/screens");
  const manifestFile = join(site, "src/content/screens.json");

  const old = JSON.parse(await readFile(manifestFile, "utf8").catch(() => "{}"));
  const items = [];
  let rewritten = 0;
  const writes = [];

  for (const shot of SHOTS) {
    for (const theme of THEMES) {
      const src = join(shots, `${shot.id}-${theme}.png`);
      const meta = await sharp(src).metadata().catch(() => {
        throw new Error(`${src} is missing: capture it first (website/README.md, "Screenshots")`);
      });
      if (meta.width !== shot.width || meta.height !== shot.height) {
        throw new Error(`${src}: ${meta.width}x${meta.height}, expected ${shot.width}x${shot.height}`);
      }
      for (const w of shot.widths) {
        const data = await (w === shot.width ? sharp(src) : sharp(src).resize({ width: w })).webp(WEBP).toBuffer();
        const prevSrc = old[shot.id]?.[theme]?.find((e) => e.w === w)?.src;
        const prevData = prevSrc ? await readFile(join(outDir, prevSrc.replace(/^\/screens\//, ""))).catch(() => null) : null;
        const prev = prevData ? await rawOf(prevData) : null;
        if (prev && !changed(prev, await rawOf(data))) {
          items.push({ id: shot.id, theme, w, src: prevSrc, bytes: prevData.length });
          continue;
        }
        const name = fileName(shot.id, theme, w, contentHash(data));
        writes.push({ name, data });
        items.push({ id: shot.id, theme, w, src: `/screens/${name}`, bytes: data.length });
        rewritten++;
      }
    }
  }

  const total = items.reduce((sum, i) => sum + i.bytes, 0);
  checkBudget(total);

  await mkdir(outDir, { recursive: true });
  for (const { name, data } of writes) await writeFile(join(outDir, name), data);
  const keep = new Set(items.map((i) => i.src.replace(/^\/screens\//, "")));
  for (const name of await readdir(outDir)) if (isScreenFile(name) && !keep.has(name)) await rm(join(outDir, name));
  await writeFile(manifestFile, JSON.stringify(buildManifest(items), null, 2) + "\n");
  console.log(`${items.length} images, ${(total / 1024).toFixed(0)} KiB of ${BUDGET_BYTES / 1024} KiB, ${rewritten} rewritten`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
