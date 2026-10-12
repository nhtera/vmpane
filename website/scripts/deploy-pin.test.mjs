// SPDX-License-Identifier: Apache-2.0

// The build checks the output with the same cf CLI that deploys it:
// package.json (build) and deploy/package.json (production) pin one version,
// and both lockfiles resolve it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const json = (rel) => JSON.parse(readFileSync(new URL(rel, import.meta.url), "utf8"));

test("one exact cf version for build and deploy", () => {
  const build = json("../package.json").devDependencies.cf;
  const deploy = json("../deploy/package.json").dependencies.cf;
  assert.match(build, /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/, "exact pin");
  assert.equal(deploy, build);
  assert.equal(json("../package-lock.json").packages["node_modules/cf"].version, build);
  assert.equal(json("../deploy/package-lock.json").packages["node_modules/cf"].version, build);
});
