// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties } from "react";
import { Icon } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { strings } from "@/content/strings";
import { RELEASES_URL } from "@/lib/urls";

const t = landing.hero;

/** The hero: meta strip, the headline with its self-drawing underline, one CTA, stickers. */
export function Hero() {
  return (
    <section className="hero">
      <div className="stickers" aria-hidden="true">
        {landing.stickers.map((s) => (
          <img
            key={s.src}
            className="st"
            src={`/stickers/${s.src}.svg`}
            alt=""
            width={s.w}
            height={s.h}
            style={{ [s.side]: s.x, top: s.y, "--d": s.d, "--r": `${s.r}deg` } as CSSProperties}
          />
        ))}
      </div>
      <div className="copy">
        <div className="meta">
          {t.meta.map((m) => (
            <span key={m}>{m}</span>
          ))}
        </div>
        <h1>
          {t.title[0]}
          <br />
          <span className="underline">
            {t.title[1]}
            <svg viewBox="0 0 300 20" preserveAspectRatio="none" aria-hidden="true">
              <path pathLength={1} d="M4 14C60 6 140 4 200 8s80 6 96 2" />
            </svg>
          </span>
        </h1>
        <p className="sub">{t.sub}</p>
        <div className="cta">
          <a className="btn btn-dark" href={RELEASES_URL}>
            <Icon name="download" />
            {strings.nav.cta}
          </a>
        </div>
      </div>
    </section>
  );
}
