// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { nav } from "@/lib/site-links";
import { sitemapXml } from "@/lib/sitemap";

// Prerendered: the landing page and every published docs page, canonical URLs only.
export const Route = createFileRoute("/sitemap.xml")({
  server: {
    handlers: {
      GET: () => new Response(sitemapXml(nav), { headers: { "content-type": "application/xml; charset=utf-8" } }),
    },
  },
});
