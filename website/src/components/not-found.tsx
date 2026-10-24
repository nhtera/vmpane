// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import { strings } from "@/content/strings";

const t = strings.notFound;

/** The 404 page: prerendered as /404.html and served by the Worker for any miss. */
export function NotFound() {
  return (
    <main id="main" className="wrap not-found">
      <p className="not-found-code">{t.code}</p>
      <h1>{t.title}</h1>
      <p>{t.body}</p>
      <div className="row">
        <Link className="btn btn-primary" to="/">
          {t.home}
        </Link>
        <Link className="btn btn-secondary" to="/docs/$" params={{ _splat: "" }}>
          {t.docs}
        </Link>
      </div>
    </main>
  );
}
