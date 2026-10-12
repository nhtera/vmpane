// SPDX-License-Identifier: Apache-2.0

import type { IconName } from "@/components/site/icons";

/** The sidebar's badge per docs page (design draft v5): an icon on a system colour, like System Settings. */
export const DOC_ICONS: Record<string, { icon: IconName; c: string }> = {
  overview: { icon: "book", c: "blue" },
  install: { icon: "download", c: "gray" },
  "guides/macos": { icon: "laptopcomputer", c: "purple" },
  "guides/linux": { icon: "terminal", c: "teal" },
  "guides/windows": { icon: "pc", c: "orange" },
  mcp: { icon: "cursor", c: "orange" },
  cli: { icon: "terminal", c: "indigo" },
  "security-model": { icon: "shield", c: "green" },
  "bundle-format": { icon: "folder", c: "indigo" },
  architecture: { icon: "square-stack", c: "gray" },
  security: { icon: "lock", c: "red" },
  contributing: { icon: "code", c: "blue" },
  "code-of-conduct": { icon: "hand", c: "pink" },
};

/** A page with no entry gets the book on gray. */
export const docIcon = (slug: string) => DOC_ICONS[slug] ?? { icon: "book" as IconName, c: "gray" };
