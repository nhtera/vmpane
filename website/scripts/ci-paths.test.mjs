// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { matches, sitePaths } from "./ci-paths.mjs";

test("the workflow's path filter is read without a YAML parser", () => {
  const globs = sitePaths("env:\n  NODE: x\n  SITE_PATHS: |\n    website/**\n    # a note\n    README.md\n\njobs:\n  x: y\n");
  assert.deepEqual(globs, ["website/**", "README.md"]);
  for (const p of ["website/**", "docs/**", "SECURITY.md", "Config/AppIcon.svg", ".github/workflows/site.yml"]) assert.ok(sitePaths().includes(p), p);
});

test("globs match folders and exact files", () => {
  const globs = ["website/**", "README.md", "Config/AppIcon.svg"];
  assert.ok(matches("website/src/x.ts", globs));
  assert.ok(matches("Config/AppIcon.svg", globs));
  assert.ok(matches("README.md", globs));
  assert.ok(!matches("docs/README.md", globs));
  assert.ok(!matches("websites/x", globs));
  assert.ok(!matches("App/Sources/VMPaneApp.swift", globs));
});
