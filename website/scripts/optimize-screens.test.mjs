// SPDX-License-Identifier: Apache-2.0
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  BUDGET_BYTES,
  PIXEL_DELTA,
  SHOTS,
  buildManifest,
  changed,
  changedShare,
  checkBudget,
  contentHash,
  fileName,
  isScreenFile,
} from "./optimize-screens.mjs";

test("names carry id, theme, width and an 8-hex content hash", () => {
  const hash = contentHash(Buffer.from("abc"));
  assert.match(hash, /^[0-9a-f]{8}$/);
  assert.equal(hash, "ba7816bf");
  assert.equal(fileName("desk-live", "dark", 2800, hash), "desk-live-dark-2800.ba7816bf.webp");
  assert.ok(isScreenFile("phone-meetings-light-590.0123abcd.webp"));
  assert.ok(!isScreenFile("favicon.svg"));
  assert.ok(!isScreenFile("notes.webp"));
});

test("the manifest keeps the landing page's shape, largest width first", () => {
  const items = [];
  for (const s of SHOTS) {
    for (const theme of ["light", "dark"]) {
      for (const w of [...s.widths].reverse()) items.push({ id: s.id, theme, w, src: `/screens/${s.id}-${theme}-${w}.x.webp` });
    }
  }
  const m = buildManifest(items);
  assert.deepEqual(Object.keys(m), ["desk-live", "desk-notes", "phone-live", "phone-meetings"]);
  assert.deepEqual(m["desk-live"].light.map((e) => e.w), [2800, 1400]);
  assert.deepEqual(m["phone-live"].dark.map((e) => e.w), [1179, 590]);
  assert.equal(m["phone-meetings"].width, 1179);
  assert.equal(m["phone-meetings"].height, 2556);
  assert.deepEqual(Object.keys(m["desk-notes"]), ["width", "height", "light", "dark"]);
});

const image = (n, fill = 100) => ({ raw: Buffer.alloc(n * 3, fill), width: n, height: 1 });

test("diff decision: none, size, noise and a real change", () => {
  const a = image(10000);
  assert.equal(changed(null, a), true);
  assert.equal(changed(a, image(10000)), false);
  assert.equal(changed(a, { ...image(5000), width: 5000 }), true);
  // Encoder noise: every pixel moves by less than the delta.
  assert.equal(changed(a, image(10000, 100 + PIXEL_DELTA)), false);
  // A visible change in 1% of the pixels.
  const b = image(10000);
  b.raw.fill(200, 0, 100 * 3);
  assert.equal(changedShare(a.raw, b.raw), 0.01);
  assert.equal(changed(a, b), true);
  // A single pixel is below the share.
  const c = image(10000);
  c.raw.fill(200, 0, 3);
  assert.equal(changed(a, c), false);
});

test("budget: at the limit passes, over it throws", () => {
  checkBudget(BUDGET_BYTES);
  assert.throws(() => checkBudget(BUDGET_BYTES + 1), /over the/);
});
