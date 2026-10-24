// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import { Icon } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { strings } from "@/content/strings";
import { RELEASES_URL } from "@/lib/urls";

const t = landing.hero;

/** The hero, Apple's way: the app icon, the headline, one line of copy, the download and the docs, the fine print. */
export function Hero() {
  return (
    <section className="hero">
      <div className="copy">
        <img className="hero-icon" src="/icon.svg" alt="" width="112" height="112" />
        <h1>
          {t.title[0]}
          <br />
          {t.title[1]}
        </h1>
        <p className="sub">{t.sub}</p>
        <div className="cta">
          <a className="btn btn-primary" href={RELEASES_URL}>
            {strings.nav.cta}
          </a>
          <Link className="more" to="/docs/$" params={{ _splat: "" }}>
            {t.docs}
            <Icon name="chevron-right" />
          </Link>
        </div>
        <p className="fine">{t.meta}</p>
      </div>
    </section>
  );
}
