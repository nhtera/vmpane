// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { isKeyChord } from "./key-chord.ts";

test("shortcuts are key chords", () => {
  for (const s of ["⌘⇧R", "⌘K", "⌘,", "⌘M", "Ctrl+K", "Ctrl+Shift+R", "Cmd+Option+F5", "⌘⇧"]) assert.ok(isKeyChord(s), s);
});

test("ordinary code is not", () => {
  for (const s of ["K", "Esc", "ghi", "ghi record", "Ctrl", "Ctrl+", "a+b", "⌘K and more", "docs/notes.md", ""]) assert.ok(!isKeyChord(s), s);
});
