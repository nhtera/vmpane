// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { THEME_INIT_SCRIPT, validTheme } from "./theme.ts";

function run(stored: string | null | "throw", osDark: boolean) {
  const listeners: ((e: { matches: boolean }) => void)[] = [];
  const documentElement = { dataset: {} as Record<string, string> };
  let store = stored;
  const ctx = {
    document: { documentElement },
    localStorage: {
      getItem: () => {
        if (store === "throw") throw new Error("blocked");
        return store;
      },
    },
    matchMedia: () => ({ matches: osDark, addEventListener: (_: string, f: (e: { matches: boolean }) => void) => listeners.push(f) }),
  };
  runInNewContext(THEME_INIT_SCRIPT, ctx);
  return {
    theme: () => documentElement.dataset.theme,
    osChange: (dark: boolean) => listeners.forEach((f) => f({ matches: dark })),
    store: (v: string | null) => {
      store = v;
    },
  };
}

test("the stored theme wins; anything else follows the OS", () => {
  assert.equal(run("dark", false).theme(), "dark");
  assert.equal(run("light", true).theme(), "light");
  assert.equal(run("blue", true).theme(), "dark");
  assert.equal(run(null, false).theme(), "light");
  assert.equal(run("throw", true).theme(), "dark");
});

test("an OS change applies only while nothing valid is stored", () => {
  const free = run(null, false);
  free.osChange(true);
  assert.equal(free.theme(), "dark");
  const picked = run("light", false);
  picked.osChange(true);
  assert.equal(picked.theme(), "light");
});

test("validTheme", () => {
  assert.equal(validTheme("dark"), "dark");
  assert.equal(validTheme("blue"), null);
  assert.equal(validTheme(undefined), null);
});
