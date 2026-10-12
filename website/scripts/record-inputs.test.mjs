// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { cssImports, outsideInputs } from "./record-inputs.mjs";

test("only repository files outside the site and node_modules are inputs", () => {
  const got = outsideInputs(
    [
      "/r/Config/AppIcon.svg?direct",
      "/r/website/src/x.ts",
      "/r/website/node_modules/react/index.js",
      "/r/node_modules/x/y.js",
      "\0virtual:x",
      "/elsewhere/a.ts",
      "/r/docs/README.md",
    ],
    "/r",
    "/r/website",
  );
  assert.deepEqual([...got].sort(), ["Config/AppIcon.svg", "docs/README.md"]);
});

test("relative CSS @imports are followed, recursively", () => {
  const files = {
    "/r/website/src/styles/site.css": '@import "tailwindcss/theme.css";\n@import "./fonts.css";\n@import "../../../Config/brand/tokens.css";',
    "/r/website/src/styles/fonts.css": "",
    "/r/Config/brand/tokens.css": '@import "./more.css";',
    "/r/Config/brand/more.css": "",
  };
  const got = cssImports("/r/website/src/styles/site.css", (f) => {
    if (!(f in files)) throw new Error("missing");
    return files[f];
  });
  assert.deepEqual([...outsideInputs(got, "/r", "/r/website")].sort(), ["Config/brand/more.css", "Config/brand/tokens.css"]);
});
