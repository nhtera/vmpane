// SPDX-License-Identifier: Apache-2.0

import { strings } from "@/content/strings";
import { absolute } from "./urls";

/** Per-route head tags: title, description, canonical, Open Graph and Twitter card. */
export function pageHead({ title, description, path }: { title: string; description: string; path: string }) {
  const url = absolute(path);
  const image = absolute("/og.png");
  return {
    meta: [
      { title },
      { name: "description", content: description },
      { property: "og:type", content: "website" },
      { property: "og:site_name", content: strings.site.name },
      { property: "og:title", content: title },
      { property: "og:description", content: description },
      { property: "og:url", content: url },
      { property: "og:image", content: image },
      { property: "og:image:width", content: "1200" },
      { property: "og:image:height", content: "630" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: title },
      { name: "twitter:description", content: description },
      { name: "twitter:image", content: image },
    ],
    links: [{ rel: "canonical", href: url }],
  };
}
