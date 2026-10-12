// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { FaqSection } from "@/components/landing/faq";
import { Icon } from "@/components/site/icons";
import { FAQ, plainAnswer } from "@/content/faq";
import { landing } from "@/content/landing";
import { strings } from "@/content/strings";
import { faqPage, jsonForScript, softwareApplication } from "@/lib/json-ld";
import { pageHead } from "@/lib/seo";
import { RELEASES_URL } from "@/lib/urls";
import { fontPreloads } from "@/styles/fonts";

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
      // The handwritten note's font, on the one page that uses it.
      links: [...head.links, ...fontPreloads],
      scripts: [{ type: "application/ld+json", children: JSON_LD }],
    };
  },
  component: Landing,
});

const t = landing.hero;

function Landing() {
  return (
    <main id="main">
      <section className="hero">
        <div className="copy">
          <div className="meta">
            {t.meta.map((m) => (
              <span key={m}>{m}</span>
            ))}
          </div>
          <h1>
            {t.title[0]}
            <br />
            {t.title[1]}
          </h1>
          <p className="sub">{t.sub}</p>
          <div className="cta">
            <span className="hand">
              {t.note}
              <svg viewBox="0 0 46 40" aria-hidden="true">
                <path d="M4 4c10 4 22 14 26 30M30 34l-8-4M30 34l3-9" />
              </svg>
            </span>
            <a className="btn btn-dark" href={RELEASES_URL}>
              <Icon name="download" />
              {strings.nav.cta}
            </a>
          </div>
        </div>
      </section>
      {/* Filled in by the landing phase: the guests tabs and the agents demo. */}
      <section className="band" id="guests" aria-labelledby="guests-title">
        <div className="wrap head">
          <h2 id="guests-title">
            {landing.guests.title[0]}
            <br />
            <span className="hl-blue">{landing.guests.title[1]}</span>
          </h2>
        </div>
      </section>
      <section className="band gray" id="agents" aria-labelledby="agents-title">
        <div className="wrap head">
          <span className="eyebrow hl-orange">{landing.agents.eyebrow}</span>
          <h2 id="agents-title">
            {landing.agents.title[0]}
            <br />
            <span className="hl-orange">{landing.agents.title[1]}</span>
          </h2>
        </div>
      </section>
      <FaqSection />
    </main>
  );
}
