// SPDX-License-Identifier: Apache-2.0

// /llms.txt (llmstxt.org): an H1, a one-paragraph summary as a blockquote,
// then one `##` section per docs nav section with `- [title](url): description`
// lines. Built from the published nav only, so it lists exactly what the docs
// site publishes.

import type { GeneratedNav } from "./site-links.ts";
import { absolute, doc } from "./urls.ts";

export interface LlmsIntro {
  name: string;
  summary: string;
  details: readonly string[];
}

const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();

export function llmsTxt(nav: GeneratedNav, intro: LlmsIntro): string {
  const out = [`# ${intro.name}`, "", `> ${oneLine(intro.summary)}`, ""];
  for (const d of intro.details) out.push(oneLine(d), "");
  for (const s of nav.sections) {
    out.push(`## ${s.title}`, "");
    for (const p of s.pages) out.push(`- [${p.title}](${absolute(doc(p.slug))}): ${oneLine(p.description)}`);
    out.push("");
  }
  return `${out.join("\n").replace(/\n+$/, "")}\n`;
}
