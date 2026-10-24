// SPDX-License-Identifier: Apache-2.0

import { type ReactNode, useEffect, useRef, useState } from "react";
import { Icon } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { ClipboardMock, ImportMock, PortsMock, SharingMock, SnapshotsMock, Win } from "./mocks";
import { TwoTone } from "./two-tone";

const t = landing.features;
type Scene = NonNullable<(typeof t.slides)[number]["scene"]>;
const SCENES: Record<Scene, ReactNode> = {
  snapshots: <SnapshotsMock />,
  ports: <PortsMock />,
  sharing: <SharingMock />,
  import: <ImportMock />,
  clipboard: <ClipboardMock />,
};

/**
 * A scroll-snap track of features with Previous and Next. The track itself is
 * focusable (arrow keys scroll it); the buttons step one slide and turn off at
 * either end. The scroll listener only updates the buttons.
 */
export function FeatureCarousel() {
  const track = useRef<HTMLDivElement>(null);
  const [ends, setEnds] = useState({ start: true, end: false });
  useEffect(() => {
    const el = track.current;
    if (!el) return;
    let frame = 0;
    const sync = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => setEnds({ start: el.scrollLeft < 8, end: el.scrollLeft + el.clientWidth > el.scrollWidth - 8 }));
    };
    sync();
    el.addEventListener("scroll", sync, { passive: true });
    addEventListener("resize", sync);
    return () => {
      cancelAnimationFrame(frame);
      el.removeEventListener("scroll", sync);
      removeEventListener("resize", sync);
    };
  }, []);
  const step = (dir: 1 | -1) => {
    const el = track.current;
    const slide = el?.querySelector(".slide");
    if (!el || !slide) return;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    el.scrollBy({ left: dir * (slide.getBoundingClientRect().width + 20), behavior: reduce ? "auto" : "smooth" });
  };
  return (
    <section className="band" aria-labelledby="features-title">
      <div className="wrap car-head">
        <h2 id="features-title">
          <TwoTone text={t.title} />
        </h2>
        <div className="car-nav">
          <button type="button" aria-label={t.prev} disabled={ends.start} onClick={() => step(-1)}>
            <Icon name="chevron-left" />
          </button>
          <button type="button" aria-label={t.next} disabled={ends.end} onClick={() => step(1)}>
            <Icon name="chevron-right" />
          </button>
        </div>
      </div>
      <div className="track" ref={track} tabIndex={0} role="group" aria-label={t.label}>
        {t.slides.map((s) => (
          <article className="slide" key={s.title}>
            <div className={`media wall-${s.wall}`}>
              {s.scene ? (
                SCENES[s.scene]
              ) : (
                <Win title={t.terminalTitle} label={t.terminal.map((line) => line.map((p) => p.t).join("")).join("\n")}>
                  <div className="term">
                    {t.terminal.map((line, i) => (
                      <span key={i}>
                        {line.map((p, j) => (
                          <span key={j} className={"d" in p ? "d" : "g" in p ? "g" : undefined}>
                            {p.t}
                          </span>
                        ))}
                        {"\n"}
                      </span>
                    ))}
                  </div>
                </Win>
              )}
            </div>
            <h3>{s.title}</h3>
            <p>{s.body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}
