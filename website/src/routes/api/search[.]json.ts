// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { buildSearchIndex } from "@/lib/search-index";
import { source } from "@/lib/source";

// Prerendered to a static JSON file; the search dialog downloads it on the
// first search. The build picks how much text to index to stay under the
// size budget (see search-index.ts).
export const Route = createFileRoute("/api/search.json")({
  server: {
    handlers: {
      GET: async () => {
        const { level, json } = await buildSearchIndex(source);
        if (level !== "full") console.warn(`search index: ${level} level (${json.length} bytes raw); the full text would not fit the gzipped size budget`);
        return new Response(json, { headers: { "content-type": "application/json" } });
      },
    },
  },
});
