// SPDX-License-Identifier: Apache-2.0

// Structured data for the landing page: SoftwareApplication and FAQPage
// (from the same FAQ data the page renders). The output goes into an inline
// <script type="application/ld+json">, hashed into the page's CSP like every
// inline script; `<` is escaped so no text can close the script element.

import { absolute, RELEASES_URL, REPO_URL } from "./urls.ts";

export interface FaqItem {
  q: string;
  a: string;
}

export function softwareApplication({ name, description }: { name: string; description: string }) {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name,
    description,
    url: absolute("/"),
    applicationCategory: "DeveloperApplication",
    operatingSystem: "macOS 15 or later",
    processorRequirements: "Apple silicon",
    downloadUrl: RELEASES_URL,
    license: "https://www.apache.org/licenses/LICENSE-2.0",
    isAccessibleForFree: true,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    codeRepository: REPO_URL,
  };
}

export function faqPage(items: readonly FaqItem[]) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((i) => ({ "@type": "Question", name: i.q, acceptedAnswer: { "@type": "Answer", text: i.a } })),
  };
}

const LS = String.fromCharCode(0x2028);
const PS = String.fromCharCode(0x2029);

/** JSON for an inline script: `<`, `>`, `&` and the JS line separators escaped. */
export function jsonForScript(data: unknown): string {
  return JSON.stringify(data)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")
    .split(LS)
    .join("\\u2028")
    .split(PS)
    .join("\\u2029");
}
