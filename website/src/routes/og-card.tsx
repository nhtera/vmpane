// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { strings } from "@/content/strings";

const t = strings.ogCard;

// The share card, 1200×630: the app icon and the hero line on the hero's
// wallpaper, captured to public/og.png by `npm run og` (test/og-capture.mjs).
// Not linked from anywhere, not in the sitemap or llms.txt, and noindex.
export const Route = createFileRoute("/og-card")({
  head: () => ({ meta: [{ title: `${strings.site.name} share card` }, { name: "robots", content: "noindex" }] }),
  component: OgCard,
});

function OgCard() {
  return (
    <main id="main" className="og-card" data-og-card="">
      <img src="/icon.svg" alt="" width="180" height="180" />
      <h1>{t.headline}</h1>
      <p>{t.sub}</p>
    </main>
  );
}
