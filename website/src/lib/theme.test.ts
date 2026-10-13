// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { THEME_INIT_SCRIPT, validTheme } from "./theme.ts";

function run(stored: string | null | "throw", osDark: boolean) {
  const documentElement = { dataset: {} as Record<string, string> };
  const ctx = {
    document: { documentElement },
    localStorage: {
      getItem: () => {
        if (stored === "throw") throw new Error("blocked");
        return stored;
      },
    },
    matchMedia: () => ({ matches: osDark, addEventListener: () => {} }),
  };
  runInNewContext(THEME_INIT_SCRIPT, ctx);
  return documentElement.dataset.theme;
}

test("light by default, whatever the OS; dark only when the reader picked it", () => {
  assert.equal(run("dark", false), "dark");
  assert.equal(run("light", true), "light");
  assert.equal(run("blue", true), "light");
  assert.equal(run(null, true), "light");
  assert.equal(run(null, false), "light");
  assert.equal(run("throw", true), "light");
});

test("validTheme", () => {
  assert.equal(validTheme("dark"), "dark");
  assert.equal(validTheme("blue"), null);
  assert.equal(validTheme(undefined), null);
});
