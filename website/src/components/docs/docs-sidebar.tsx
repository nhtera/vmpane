// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import type { CSSProperties } from "react";
import { Icon } from "@/components/site/icons";
import { docIcon } from "@/content/docs-icons";
import { docsStrings } from "@/content/docs-strings";
import { strings } from "@/content/strings";
import { nav } from "@/lib/site-links";
import { SearchButton } from "./docs-search";

/** The docs navigation: the published nav's sections, in order, each page with its badge. */
export function DocsNav({ slug }: { slug: string }) {
  return (
    <nav aria-label={strings.docs.navLabel} className="docs-nav">
      {nav.sections.map((section) => (
        <div className="nav-group" key={section.title}>
          <p>{section.title}</p>
          {section.pages.map((page) => {
            const badge = docIcon(page.slug);
            return (
              <Link key={page.slug} to="/docs/$" params={{ _splat: page.slug }} activeOptions={{ exact: true }} aria-current={slug === page.slug ? "page" : undefined}>
                <span className="ic" style={{ "--c": `var(--${badge.c})` } as CSSProperties} aria-hidden="true">
                  <Icon name={badge.icon} />
                </span>
                {page.title}
              </Link>
            );
          })}
        </div>
      ))}
    </nav>
  );
}

/** Wide screens: a sticky sidebar with the search button above the nav. */
export function DocsSidebar({ slug }: { slug: string }) {
  return (
    <aside className="docs-side" aria-label={docsStrings.sidebar}>
      <SearchButton />
      <DocsNav slug={slug} />
    </aside>
  );
}
