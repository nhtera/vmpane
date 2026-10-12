// SPDX-License-Identifier: Apache-2.0

import { useEffect, useRef } from "react";
import { strings } from "@/content/strings";
import { SearchButton } from "./docs-search";
import { DocsNav } from "./docs-sidebar";

/** 900 px and narrower: the sidebar becomes a "Docs menu" disclosure. */
export function DocsMenu({ slug }: { slug: string }) {
  const details = useRef<HTMLDetailsElement>(null);
  // A page change (a click in the menu) folds it back up.
  useEffect(() => {
    if (details.current) details.current.open = false;
  }, [slug]);
  return (
    <details className="docs-menu" ref={details}>
      <summary>{strings.docs.menu}</summary>
      <div className="docs-side-inner">
        <SearchButton />
        <DocsNav slug={slug} />
      </div>
    </details>
  );
}
