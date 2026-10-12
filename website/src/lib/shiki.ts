// SPDX-License-Identifier: Apache-2.0

import type { ThemeRegistration } from "shiki";

// Code colours are CSS variables (src/styles/tokens.css), so one theme serves
// dark and light and follows the theme toggle with no re-render. The text
// tints double as syntax colours: they are AA on --band, the code block's
// background, in both themes (shiki.test.ts).
export const vmpaneTheme: ThemeRegistration = {
  name: "vmpane",
  type: "dark",
  colors: {
    "editor.foreground": "var(--text)",
    "editor.background": "var(--band)",
  },
  fg: "var(--text)",
  bg: "var(--band)",
  tokenColors: [
    { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: "var(--text-2)" } },
    { scope: ["string", "string.regexp", "markup.inline.raw"], settings: { foreground: "var(--t-green)" } },
    { scope: ["constant.numeric", "constant.language", "constant.character", "constant.other"], settings: { foreground: "var(--t-orange)" } },
    { scope: ["entity.name.section", "markup.heading", "entity.name.tag"], settings: { foreground: "var(--t-purple)" } },
    { scope: ["support.type.property-name", "meta.object-literal.key", "variable.other.property", "entity.name.tag.toml", "keyword.key.toml"], settings: { foreground: "var(--t-blue)" } },
    { scope: ["variable.parameter", "variable.other.readwrite", "punctuation.definition.variable"], settings: { foreground: "var(--t-red)" } },
    { scope: ["support.function", "entity.name.function", "entity.other.attribute-name"], settings: { foreground: "var(--t-blue)" } },
    { scope: ["keyword", "storage", "storage.type", "keyword.operator"], settings: { foreground: "var(--t-purple)" } },
    { scope: ["punctuation", "meta.brace"], settings: { foreground: "var(--text-2)" } },
  ],
};
