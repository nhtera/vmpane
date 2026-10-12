// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { robotsTxt } from "@/lib/sitemap";

export const Route = createFileRoute("/robots.txt")({
  server: {
    handlers: {
      GET: () => new Response(robotsTxt(), { headers: { "content-type": "text/plain; charset=utf-8" } }),
    },
  },
});
