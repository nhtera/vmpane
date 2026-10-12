// SPDX-License-Identifier: Apache-2.0

import { type ReactNode, useEffect, useRef } from "react";
import { pageContext } from "@/lib/docs-toc";
import { nav } from "@/lib/site-links";
import { DocsMenu } from "./docs-menu";
import { DocsSearchProvider } from "./docs-search";
import { DocsSidebar } from "./docs-sidebar";
import { IndexCards } from "./index-cards";
import { PageFooter } from "./page-footer";
import { Pager } from "./pager";

/** The three-column docs layout: sidebar | article | table of contents (both are children). */
export function DocsShell({ slug, children }: { slug: string; children: ReactNode }) {
  return (
    <DocsSearchProvider>
      <main id="main" className="wrap docs">
        <DocsSidebar slug={slug} />
        <DocsMenu slug={slug} />
        {children}
      </main>
    </DocsSearchProvider>
  );
}

interface ArticleProps {
  slug: string;
  title: string;
  description: string;
  source: string;
  lastUpdated?: string;
  children: ReactNode;
}

// True once a docs page has been shown in this tab: the next one is a client-side change.
let shown = false;

/** One docs page: crumb, title, lead, body, pager and footer. */
export function DocsArticle({ slug, title, description, source, lastUpdated, children }: ArticleProps) {
  const { section, previous, next } = pageContext(nav, slug);
  const heading = useRef<HTMLHeadingElement>(null);

  // After a client-side page change, keyboard and screen-reader users land on
  // the new title (a reload would have put them there). A link to a heading
  // keeps the browser's scroll target instead.
  useEffect(() => {
    if (shown && !window.location.hash) heading.current?.focus({ preventScroll: true });
    shown = true;
  }, [slug]);

  return (
    <article className="article" data-docs-article="">
      {section ? <p className="crumb">{section}</p> : null}
      <h1 ref={heading} tabIndex={-1}>
        {title}
      </h1>
      <p className="lead">{description}</p>
      {children}
      {slug === "" ? <IndexCards /> : null}
      <Pager previous={previous} next={next} />
      <PageFooter source={source} lastUpdated={lastUpdated} />
    </article>
  );
}
