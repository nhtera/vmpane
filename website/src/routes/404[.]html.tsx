// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import { NotFound } from "@/components/not-found";
import { strings } from "@/content/strings";

// Prerendered as 404.html at the root of the assets, then made static
// (scripts/static-404.mjs). The Worker answers every path that has no asset
// with it, status 404 (src/server.ts).
export const Route = createFileRoute("/404.html")({
  head: () => ({ meta: [{ title: strings.notFound.metaTitle }, { name: "robots", content: "noindex" }] }),
  component: NotFound,
});
