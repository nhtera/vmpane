// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { buildDocsIndex } from "@/lib/docs-data";

// Prerendered to a static JSON file: the page tree and the page list the
// docs route reads on client-side navigation.
export const Route = createFileRoute("/api/docs-tree.json")({
  server: {
    handlers: {
      GET: async () => Response.json(await buildDocsIndex()),
    },
  },
});
