// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { headersFor, parseHeadersFile } from "./headers-file.mjs";

const FILE = `/*
  X-Frame-Options: DENY
  Strict-Transport-Security: max-age=1

/assets/*
  Cache-Control: immutable

/docs/cli
  Content-Security-Policy: default-src 'self'; script-src 'self' 'sha256-a+b='
`;

test("every matching rule applies; exact paths and splats", () => {
  const rules = parseHeadersFile(FILE);
  assert.deepEqual(headersFor(rules, "/docs/cli"), {
    "x-frame-options": "DENY",
    "strict-transport-security": "max-age=1",
    "content-security-policy": "default-src 'self'; script-src 'self' 'sha256-a+b='",
  });
  assert.equal(headersFor(rules, "/assets/x.js")["cache-control"], "immutable");
  assert.equal(headersFor(rules, "/docs/cli/x")["content-security-policy"], undefined);
  assert.equal(headersFor(rules, "/docs/clix")["content-security-policy"], undefined);
  assert.throws(() => parseHeadersFile("  X: y\n"), /bad line/);
});
