// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { checkLock, isAllowed } from "./check-npm-licenses.mjs";

test("SPDX expressions", () => {
  assert.ok(isAllowed("MIT"));
  assert.ok(isAllowed("(MIT OR GPL-3.0)"));
  assert.ok(isAllowed("MIT AND Apache-2.0"));
  assert.ok(!isAllowed("MIT AND GPL-3.0"));
  assert.ok(!isAllowed("LGPL-3.0-or-later"));
  assert.ok(!isAllowed("SEE LICENSE IN LICENSE"));
  assert.ok(!isAllowed(undefined));
  assert.ok(!isAllowed("(MIT"));
});

test("dev packages and build-only tools are skipped; a shipped GPL package fails", () => {
  const { bad, n } = checkLock({
    packages: {
      "": {},
      "node_modules/a": { license: "MIT" },
      "node_modules/b": { license: "GPL-3.0", dev: true },
      "node_modules/caniuse-lite": { license: "CC-BY-4.0" },
      "node_modules/c": { license: "GPL-3.0" },
    },
  });
  assert.equal(n, 2);
  assert.deepEqual(bad, ["c: license GPL-3.0 is not allowed"]);
});
