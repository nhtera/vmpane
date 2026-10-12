// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { parse } from "yaml";
import { expandQuickstart, frontmatter, parseQuickstart, splitTitle, sync } from "./sync-docs.mjs";

test("the title is the first H1 after HTML comments", () => {
  const { title, body } = splitTitle("<!-- Generated.\n Do not edit. -->\n\n# The `ghi` command\n\nRun it.\n");
  assert.equal(title, "The ghi command");
  assert.equal(body, "Run it.\n");
  assert.throws(() => splitTitle("Intro\n\n# Late title"), /first line/);
});

test("YAML-hostile titles and descriptions round-trip", () => {
  const data = { title: 'Notes: "and" citations', description: "a: b # c — `x` 'y' {z} [w] *v &u !t |s >r", source: "docs/x.md" };
  const text = frontmatter(data);
  assert.deepEqual(parse(text.replace(/^---\n|---\n\n$/g, "")), data);
});

test("the install command comes from README.md, one sh block", () => {
  const readme = readFileSync(new URL("../../README.md", import.meta.url), "utf8");
  const { commands } = parseQuickstart(readme);
  assert.equal(commands, "brew install --cask nhtera/tap/vmpane");
  assert.ok(!commands.includes("```"));
  assert.throws(() => parseQuickstart("# x\n## Other\n"), /no "## Install"/);
  assert.throws(() => parseQuickstart("# x\n\n## Install\n\ntext\n\n## Next\n"), /exactly one/);
  assert.throws(() => parseQuickstart("# x\n\n## Install\n\n```sh\na\n```\n\n```sh\nb\n```\n"), /exactly one/);
  assert.equal(expandQuickstart("Before\n<!-- quickstart -->\nAfter", { commands: "a\nb" }), "Before\n```sh\na\nb\n```\nAfter");
});

/** A minimal repository with the docs layout the nav expects. */
function fixtureRepo({ shallow = false } = {}) {
  const repo = mkdtempSync(join(tmpdir(), "vmpane-sync-"));
  const w = (rel, text) => {
    mkdirSync(join(repo, rel, ".."), { recursive: true });
    writeFileSync(join(repo, rel), text);
  };
  w(
    "docs/README.md",
    "# Docs\n\n## Get started\n\n| Page | Contents |\n|---|---|\n| [install.md](install.md) | DMG or Homebrew |\n\n## Project\n\n| Page | Contents |\n|---|---|\n| [Security policy](../SECURITY.md) | How to report a vulnerability |\n| [guides/linux.md](guides/linux.md) | Linux guests |\n\n## Repository files (not published)\n\n- [ADR](adr/0001-x.md)\n",
  );
  w("docs/install.md", "# Install VMPane\n\nRun this:\n\n<!-- quickstart -->\n\nSee [security](../SECURITY.md).\n");
  w("docs/guides/linux.md", "# Linux guests\n\nNotes.\n");
  w("docs/adr/0001-x.md", "# ADR\n");
  w("SECURITY.md", "# Security\n\nReport privately.\n");
  w("README.md", "# VMPane\n\n## Install\n\nWith Homebrew:\n\n```sh\nbrew install --cask x/tap/y\n```\n\nMore.\n\n## Limits\n");
  const git = (...args) => execFileSync("git", args, { cwd: repo, env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
  git("init", "-q", "-b", "main");
  git("add", "-A");
  git("commit", "-qm", "init");
  if (!shallow) return repo;
  const clone = mkdtempSync(join(tmpdir(), "vmpane-sync-shallow-"));
  execFileSync("git", ["clone", "-q", "--depth", "1", `file://${repo}`, clone]);
  rmSync(repo, { recursive: true, force: true });
  return clone;
}

test("sync writes docs with frontmatter, meta.json, nav, quick start and inputs", () => {
  const repo = fixtureRepo();
  const out = join(repo, "out");
  const logs = [];
  // Dates on, whatever VMPANE_SITE_NO_DATES says in this shell.
  const { unpublished } = sync({ repo, out, dates: true, log: (m) => logs.push(m) });
  const install = readFileSync(join(out, "docs/install.md"), "utf8");
  assert.match(install, /^---\ntitle: Install VMPane\ndescription: DMG or Homebrew\nsource: docs\/install\.md\nlastUpdated: \d{4}-\d{2}-\d{2}\n---\n\nRun this:\n\n```sh\nbrew install --cask x\/tap\/y\n```\n/);
  assert.match(readFileSync(join(out, "docs/security.md"), "utf8"), /source: SECURITY\.md/);
  assert.match(readFileSync(join(out, "docs/guides/linux.md"), "utf8"), /title: Linux guests/);
  assert.deepEqual(JSON.parse(readFileSync(join(out, "docs/meta.json"), "utf8")).pages, ["index", "---Get started---", "install", "---Project---", "security", "guides/linux"]);
  const nav = JSON.parse(readFileSync(join(out, "generated/nav.json"), "utf8"));
  assert.deepEqual(nav.sections.map((s) => [s.title, s.pages.map((p) => p.slug)]), [["Get started", ["install"]], ["Project", ["security", "guides/linux"]]]);
  assert.equal(nav.sections[0].pages[0].title, "Install VMPane");
  // The nav name is the row's label when it has one; the page keeps its H1.
  assert.equal(nav.sections[1].pages[0].title, "Security policy");
  assert.match(readFileSync(join(out, "docs/security.md"), "utf8"), /^---\ntitle: Security\n/);
  assert.deepEqual(JSON.parse(readFileSync(join(out, "generated/quickstart.json"), "utf8")), { commands: "brew install --cask x/tap/y" });
  assert.deepEqual(unpublished, ["docs/adr/0001-x.md"]);
  assert.ok(logs.some((l) => l.startsWith("unpublished docs: docs/adr/0001-x.md")));
  const inputs = JSON.parse(readFileSync(join(out, "generated/inputs.json"), "utf8"));
  for (const p of ["README.md", "docs/README.md", "docs/install.md", "docs/guides/linux.md", "SECURITY.md"]) assert.ok(inputs.includes(p), p);
  // Idempotent: a second run gives the same files.
  sync({ repo, out, dates: true, log: () => {} });
  assert.equal(readFileSync(join(out, "docs/install.md"), "utf8"), install);
  rmSync(repo, { recursive: true, force: true });
});

test("sync fails on a missing doc, a refused row, a missing H1, an image and a shallow clone", () => {
  const run = (repo, extra = {}) => sync({ repo, out: join(repo, "out"), dates: false, log: () => {}, ...extra });
  let repo = fixtureRepo();
  rmSync(join(repo, "docs/install.md"));
  assert.throws(() => run(repo), /docs\/install\.md: listed in the docs nav but missing/);
  rmSync(repo, { recursive: true, force: true });

  repo = fixtureRepo();
  writeFileSync(join(repo, "docs/README.md"), readFileSync(join(repo, "docs/README.md"), "utf8").replace("| [install.md](install.md) |", "| [adr/0001-x.md](adr/0001-x.md) |"));
  assert.throws(() => run(repo), /only docs\/guides\//);
  rmSync(repo, { recursive: true, force: true });

  repo = fixtureRepo();
  writeFileSync(join(repo, "docs/install.md"), "No heading here.\n");
  assert.throws(() => run(repo), /"# Title" heading/);
  rmSync(repo, { recursive: true, force: true });

  repo = fixtureRepo();
  writeFileSync(join(repo, "SECURITY.md"), "# Security\n\n![x](x.png)\n");
  assert.throws(() => run(repo), /images are not supported/);
  rmSync(repo, { recursive: true, force: true });

  repo = fixtureRepo({ shallow: true });
  assert.throws(() => sync({ repo, out: join(repo, "out"), dates: true, log: () => {} }), /shallow clone/);
  run(repo);
  assert.doesNotMatch(readFileSync(join(repo, "out/docs/install.md"), "utf8"), /lastUpdated/);
  rmSync(repo, { recursive: true, force: true });
});
