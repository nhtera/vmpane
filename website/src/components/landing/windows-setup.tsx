// SPDX-License-Identifier: Apache-2.0

import { useEffect, useRef } from "react";
import { landing } from "@/content/landing";
import { TwoTone } from "./two-tone";

const t = landing.windows;

/**
 * The unattended Windows install as a four-step timeline. It fills once as it
 * comes into view: armed (the from-state) only when it is below the fold, the
 * reader allows motion and the browser can observe it; otherwise it is simply
 * full. One observer, no scroll listener.
 */
export function WindowsSetup() {
  const timeline = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = timeline.current;
    if (!el || matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
    if (el.getBoundingClientRect().top <= innerHeight) return;
    el.classList.add("armed");
    const obs = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        el.classList.replace("armed", "run");
        obs.disconnect();
      },
      { threshold: 0.4 },
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);
  return (
    <section className="band gray" aria-labelledby="windows-title">
      <div className="wrap">
        <div className="head split">
          <h2 id="windows-title">
            <TwoTone text={t.title} />
          </h2>
          <p>
            {t.lead[0]}
            <b>{t.lead[1]}</b>
            {t.lead[2]}
          </p>
        </div>
        <div className="timeline" ref={timeline}>
          <span className="fill" aria-hidden="true" />
          {t.steps.map((s) => (
            <div className="tstep" key={s.k}>
              <span className="k">{s.k}</span>
              <b>{s.title}</b>
              <span>{s.body}</span>
              {"min" in s ? <span className="min">{s.min}</span> : null}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
