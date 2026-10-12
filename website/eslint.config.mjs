// SPDX-License-Identifier: Apache-2.0

import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

// Safe rendering: docs content is untrusted (a pull request can change it),
// so nothing here renders raw HTML or parses Markdown at runtime.
const safeRendering = {
  rules: {
    "no-restricted-syntax": [
      "error",
      { selector: "JSXAttribute[name.name='dangerouslySetInnerHTML']", message: "Render text nodes only (no raw HTML)." },
      { selector: "AssignmentExpression[left.property.name=/^(innerHTML|outerHTML)$/]", message: "Render text nodes only (no raw HTML)." },
    ],
    "no-restricted-imports": [
      "error",
      {
        paths: ["react-markdown", "marked", "markdown-it", "dompurify", "html-react-parser"].map((name) => ({
          name,
          message: "Untrusted text is never rendered as Markdown/HTML at runtime.",
        })),
      },
    ],
  },
};

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommended,
  reactHooks.configs.flat["recommended-latest"],
  {
    files: ["src/**/*.{ts,tsx}", "*.ts"],
    languageOptions: {
      globals: { ...globals.browser },
    },
    rules: {
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
  { files: ["src/**/*.{ts,tsx}"], ...safeRendering },
  {
    files: ["*.mjs", "*.config.ts", "scripts/**/*.mjs", "deploy/*.mjs", "test/**/*.mjs", "src/**/*.test.ts"],
    languageOptions: {
      globals: { ...globals.node },
    },
  },
  {
    // Browser tests: Node code that also passes functions to the page.
    files: ["test/browser/**/*.mjs", "test/*.mjs"],
    languageOptions: {
      globals: { ...globals.node, ...globals.browser },
    },
  },
  {
    ignores: ["dist/**", "node_modules/**", ".source/**", ".output/**", ".tanstack/**", ".wrangler/**", ".cloudflare/**", "content/**", "src/routeTree.gen.ts", "deploy/node_modules/**"],
  },
);
