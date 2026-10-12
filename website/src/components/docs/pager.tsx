// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import { strings } from "@/content/strings";
import type { NavPage } from "@/lib/site-links";

/** Previous and next page across the whole nav order. */
export function Pager({ previous, next }: { previous?: NavPage; next?: NavPage }) {
  if (!previous && !next) return null;
  return (
    <nav className="pager" aria-label={strings.docs.pager}>
      {previous ? (
        <Link className="prev" to="/docs/$" params={{ _splat: previous.slug }} rel="prev">
          <small>{strings.docs.previous}</small>
          {previous.title}
        </Link>
      ) : null}
      {next ? (
        <Link className="next" to="/docs/$" params={{ _splat: next.slug }} rel="next">
          <small>{strings.docs.next}</small>
          {next.title}
        </Link>
      ) : null}
    </nav>
  );
}
