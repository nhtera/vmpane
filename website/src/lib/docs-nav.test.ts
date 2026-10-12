// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { test } from "node:test";
import { loadNav, parseNav, plainText, publishedSources } from "./docs-nav.ts";

const repo = new URL("../../../", import.meta.url).pathname;

const FIXTURE = `# VMPane docs

<!-- comment -->

## Get started

| Page | Contents |
|---|---|
| [overview.md](overview.md) | What VMPane is, and what ships **today** |
| [install.md](install.md) | Install with \`brew\` |

## Reference

| Page | Contents |
|---|---|
| [Security policy](../SECURITY.md) | How to report a vulnerability |

## Project

| Page | Contents |
|---|---|
| [guides/linux.md](guides/linux.md) | Linux guests |

## Repository files (not published)

- [CONTRIBUTING](../CONTRIBUTING.md): how to help
- [Release](release.md)
- [LICENSE](../LICENSE)

\`\`\`md
| [ignored.md](ignored.md) | inside a code fence |
\`\`\`
`;

test("sections and rows parse in order, with plain-text descriptions; bullets are ignored", () => {
  const nav = parseNav(FIXTURE);
  assert.deepEqual(nav.map((s) => s.title), ["Get started", "Reference", "Project"]);
  assert.deepEqual(nav[0].docs, [
    { source: "docs/overview.md", slug: "overview", description: "What VMPane is, and what ships today" },
    { source: "docs/install.md", slug: "install", description: "Install with brew" },
  ]);
  // A link text that is a label (not the file name) becomes the sidebar name.
  assert.deepEqual(nav[1].docs[0], { source: "SECURITY.md", slug: "security", description: "How to report a vulnerability", label: "Security policy" });
  assert.equal(nav[0].docs[0].label, undefined);
  assert.equal(nav[2].docs[0].slug, "guides/linux");
  const published = publishedSources(nav);
  assert.ok(!published.has("CONTRIBUTING.md"), "a bullet link is not published");
  assert.ok(!published.has("docs/release.md"));
  assert.ok(!published.has("docs/ignored.md"));
  assert.equal(published.get("docs/README.md"), "");
});

test("refused rows fail: docs/adr, other root files, duplicates, rows before a section", () => {
  const nav = (row: string) => parseNav(`# Docs\n\n## S\n\n| Page | Contents |\n|---|---|\n${row}\n`);
  assert.throws(() => nav("| [adr/0001-display-path.md](adr/0001-display-path.md) | x |"), /only docs\/guides\//);
  assert.throws(() => nav("| [../LICENSE](../LICENSE) | x |"), /outside docs/);
  assert.throws(() => nav("| [../README.md](../README.md) | x |"), /outside docs/);
  assert.throws(() => nav("| [a.md](a.md) | x |\n| [a.md](a.md) | y |"), /listed twice/);
  assert.throws(() => parseNav("# Docs\n\n| [a.md](a.md) | x |\n"), /not under a "## Section"/);
  assert.throws(() => parseNav("# Docs\n\n## Only bullets\n\n- [a](a.md)\n"), /no table rows/);
  // Two rows for one slug (docs/security.md and ../SECURITY.md).
  assert.throws(() => nav("| [security.md](security.md) | x |\n| [../SECURITY.md](../SECURITY.md) | y |"), /listed twice/);
  // A row under a ### heading is not under a ## section.
  assert.throws(() => parseNav("# Docs\n\n## S\n\n| [a.md](a.md) | x |\n\n### Sub\n\n| [b.md](b.md) | y |\n"), /not under a "## Section"/);
});

// The internal docs stay on GitHub (default-deny): the release process, the
// developer guide, the wire protocols, the live checklist and the ADRs.
const INTERNAL_DOCS = ["docs/release.md", "docs/release-checklist.md", "docs/development.md", "docs/control-protocol.md", "docs/agent-protocol.md", "docs/live-capabilities.md"];

test("the repository's docs/README.md parses and publishes no internal doc", () => {
  const published = publishedSources(loadNav(repo));
  assert.ok(published.has("SECURITY.md"));
  assert.ok(published.has("docs/mcp.md"));
  for (const source of published.keys()) {
    assert.ok(!INTERNAL_DOCS.includes(source), source);
    assert.ok(!source.startsWith("docs/adr/"), source);
  }
});

test("rows in HTML comments and ~~~ fences are not published", () => {
  const md = "# Docs\n\n## S\n\n| [a.md](a.md) | x |\n<!--\n| [hidden.md](hidden.md) | y |\n-->\n<!-- | [inline.md](inline.md) | z | -->\n~~~md\n| [fenced.md](fenced.md) | w |\n```\n| [still.md](still.md) | v |\n~~~\n";
  assert.deepEqual(parseNav(md)[0].docs.map((d) => d.slug), ["a"]);
});

test("markdown to plain text", () => {
  assert.equal(plainText("See [x](x.md) and `--jobs` **now**"), "See x and --jobs now");
});
