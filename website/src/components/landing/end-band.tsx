// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import quickstart from "../../../content/generated/quickstart.json" with { type: "json" };
import { landing } from "@/content/landing";
import { strings } from "@/content/strings";
import { RELEASES_URL } from "@/lib/urls";
import { TwoTone } from "./two-tone";

const t = landing.end;

/** The closing band: the app icon, one CTA, the docs, and the install command from README.md's Install section. */
export function EndBand() {
  return (
    <section className="end" aria-labelledby="end-title">
      <img className="app" src="/icon.svg" alt="" width="128" height="128" />
      <h2 id="end-title">
        <TwoTone text={t.title} />
      </h2>
      <p>{t.body}</p>
      <div className="row">
        <a className="btn btn-primary" href={RELEASES_URL}>
          {strings.nav.cta}
        </a>
        <Link className="btn btn-secondary" to="/docs/$" params={{ _splat: "" }}>
          {t.docs}
        </Link>
      </div>
      <code className="brew">
        <span className="d">$</span> {quickstart.commands}
      </code>
    </section>
  );
}
