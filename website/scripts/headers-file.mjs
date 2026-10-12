// SPDX-License-Identifier: Apache-2.0

// Reads a Cloudflare `_headers` file (the one scripts/csp-headers.mjs
// writes) and answers which headers a path gets: every matching rule
// applies, in file order (exact paths and `*` splats). A parser of its own,
// not the generator's, so tests that serve the build with it check the file
// independently.

/** `_headers` text → [{ pattern, re, headers: [name, value][] }]. */
export function parseHeadersFile(text) {
  const rules = [];
  let current;
  for (const raw of text.split("\n")) {
    if (raw.trim() === "" || raw.trim().startsWith("#")) continue;
    if (!/^\s/.test(raw)) {
      const pattern = raw.trim();
      const re = new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`);
      current = { pattern, re, headers: [] };
      rules.push(current);
      continue;
    }
    const i = raw.indexOf(":");
    if (!current || i < 0) throw new Error(`_headers: bad line "${raw}"`);
    current.headers.push([raw.slice(0, i).trim(), raw.slice(i + 1).trim()]);
  }
  return rules;
}

/** The headers for a request path, as an object (later rules add to earlier ones). */
export function headersFor(rules, path) {
  const out = {};
  for (const rule of rules) if (rule.re.test(path)) for (const [k, v] of rule.headers) out[k.toLowerCase()] = v;
  return out;
}
