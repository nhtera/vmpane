// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { strings } from "@/content/strings";
import { llmsTxt } from "@/lib/llms";
import { nav } from "@/lib/site-links";

// Prerendered: an index of the published docs for language models (llmstxt.org).
export const Route = createFileRoute("/llms.txt")({
  server: {
    handlers: {
      GET: () =>
        new Response(llmsTxt(nav, { name: strings.site.name, ...strings.llms }), {
          headers: { "content-type": "text/plain; charset=utf-8" },
        }),
    },
  },
});
