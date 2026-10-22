// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { AgentsDemo } from "@/components/landing/agents-demo";
import { EndBand } from "@/components/landing/end-band";
import { FaqSection } from "@/components/landing/faq";
import { FeatureCarousel } from "@/components/landing/feature-carousel";
import { Guests } from "@/components/landing/guests";
import { Hero } from "@/components/landing/hero";
import { Limits } from "@/components/landing/limits";
import { MacStory } from "@/components/landing/mac-story";
import { Requirements } from "@/components/landing/requirements";
import { SafetyBento } from "@/components/landing/safety-bento";
import { WindowsSetup } from "@/components/landing/windows-setup";
import { FAQ, plainAnswer } from "@/content/faq";
import { strings } from "@/content/strings";
import { faqPage, jsonForScript, softwareApplication } from "@/lib/json-ld";
import { pageHead } from "@/lib/seo";

// Structured data: an inline script, hashed into this page's CSP at build time.
const JSON_LD = jsonForScript([
  softwareApplication({ name: strings.site.name, description: strings.site.description }),
  faqPage(FAQ.map((f) => ({ q: f.q, a: plainAnswer(f.a) }))),
]);

export const Route = createFileRoute("/")({
  head: () => {
    const head = pageHead({ title: strings.site.title, description: strings.site.description, path: "/" });
    return {
      ...head,
      scripts: [{ type: "application/ld+json", children: JSON_LD }],
    };
  },
  component: Landing,
});

/** The landing page, in the draft's order. */
function Landing() {
  return (
    <main id="main">
      <Hero />
      <MacStory />
      <Guests />
      <WindowsSetup />
      <AgentsDemo />
      <SafetyBento />
      <FeatureCarousel />
      <Limits />
      <Requirements />
      <FaqSection />
      <EndBand />
    </main>
  );
}
