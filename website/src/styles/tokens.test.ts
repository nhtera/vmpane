// SPDX-License-Identifier: Apache-2.0

// tokens.css is the only place colours live. Every variable the site's CSS,
// the code highlighter and the components read is a token, a variable the
// same stylesheet declares, or one of the few a component sets per element
// (a dot's colour, a word's place in the statement, a client's angle on the orbit).

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const here = new URL(".", import.meta.url);
const read = (rel: string) => readFileSync(new URL(rel, here), "utf8");

const tokens = read("./tokens.css");
const declared = (css: string) => new Set([...css.matchAll(/(--[a-z0-9-]+)\s*:/g)].map((m) => m[1]));
const defined = declared(tokens);

/** Variables a component sets in a style prop. */
const ELEMENT_VARIABLES = ["--c", "--i", "--a"];

/** Every stylesheet but tokens.css. */
const CSS = readdirSync(here)
  .filter((f) => f.endsWith(".css") && f !== "tokens.css")
  .map((f) => `./${f}`);
const used = (source: string) => [...new Set([...source.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]))];

function sourceFiles(dir: URL): URL[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const url = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
    if (e.isDirectory()) return sourceFiles(url);
    return /\.tsx?$/.test(e.name) && !e.name.endsWith(".test.ts") ? [url] : [];
  });
}

for (const file of CSS) {
  test(`variables used by ${file} are tokens or its own`, () => {
    const css = read(file);
    const own = declared(css);
    const missing = used(css).filter((n) => !defined.has(n) && !own.has(n) && !ELEMENT_VARIABLES.includes(n));
    assert.deepEqual(missing, [], `not in tokens.css: ${missing.join(", ")}`);
  });
}

test("variables the components and the highlighter read are tokens", () => {
  const css = CSS.map(read).join("\n");
  const own = declared(css);
  for (const url of sourceFiles(new URL("../", here))) {
    const missing = used(readFileSync(url, "utf8")).filter((n) => !defined.has(n) && !own.has(n) && !ELEMENT_VARIABLES.includes(n));
    assert.deepEqual(missing, [], `${url.pathname}: ${missing.join(", ")}`);
  }
});

test("tokens.css defines both themes and the Reduce Transparency fallback", () => {
  // light by default: the OS setting never turns the site dark, only the reader's pick (data-theme="dark")
  assert.doesNotMatch(tokens, /prefers-color-scheme/);
  // (a section can also take the dark look in either theme, with .theme-dark)
  assert.match(tokens, /:root\[data-theme="dark"\], \.theme-dark \{/);
  assert.match(tokens, /@media \(prefers-reduced-transparency: reduce\) \{\s*:root \{ --glass: 100% !important; --glass-nav: 100% !important; \}/);
  for (const name of ["--bg", "--band", "--text", "--text-2", "--text-3", "--hair", "--glass", "--rim", "--pin-top", "--f-sans"]) {
    assert.ok(defined.has(name), name);
  }
});

test("the dark block redefines only names the light theme defines", () => {
  const blocks = [...tokens.matchAll(/:root\[data-theme="dark"\], \.theme-dark \{([^}]*)\}/g)].map((m) => [...declared(m[1])]);
  assert.equal(blocks.length, 1);
  const light = declared(tokens.match(/:root \{([^}]*)\}/)?.[1] ?? "");
  assert.deepEqual(blocks[0].filter((n) => !light.has(n)), []);
});

/** Colour values: hex, colour functions, named colours as CSS values, Tailwind palette classes. */
const CSS_COLOUR = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|:\s*(?:white|black|red|blue|green|gray|grey|orange|yellow|purple|pink)\b/g;
const CODE_COLOUR = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b(?!-)|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|\b(?:bg|text|border|fill|stroke)-(?:white|black|(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3})\b/g;

test("no colour values outside tokens.css", () => {
  assert.ok(CSS.includes("./site.css") && CSS.includes("./landing.css"));
  for (const file of CSS) assert.deepEqual(read(file).match(CSS_COLOUR) ?? [], [], file);
  for (const url of sourceFiles(new URL("../", here))) {
    assert.deepEqual(readFileSync(url, "utf8").match(CODE_COLOUR) ?? [], [], url.pathname);
  }
});
