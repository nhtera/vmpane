// SPDX-License-Identifier: Apache-2.0

import { type ReactNode, useEffect, useRef, useState } from "react";
import { REDUCED_MOTION, useMediaQuery } from "./hooks/use-media-query";
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

/** How long each slide stays before the gallery moves on by itself (the progress pill fills in this time). */
const DWELL = 5000;

/** Scroll the track to slide `i` (slides are 20 px apart). */
function scrollToSlide(el: HTMLElement | null, i: number, smooth: boolean) {
  const slide = el?.querySelector(".slide");
  if (!el || !slide) return;
  el.scrollTo({ left: i * (slide.getBoundingClientRect().width + 20), behavior: smooth ? "smooth" : "auto" });
}

/**
 * A scroll-snap track of features with Previous and Next. The track itself is
 * focusable (arrow keys scroll it); the buttons step one slide and turn off at
 * either end. The scroll listener only updates the buttons and the dots.
 * Under the track, a play/pause button and a dot per slide (the current one a
 * pill that fills): while the gallery is on screen it moves on every few
 * seconds, back to the start after the last slide. It holds while the pointer
 * or focus is on it, stops for good when the reader steps it or presses pause,
 * and never starts with reduced motion.
 */
export function FeatureCarousel() {
  const track = useRef<HTMLDivElement>(null);
  const section = useRef<HTMLElement>(null);
  const [ends, setEnds] = useState({ start: true, end: false });
  const [current, setCurrent] = useState(0);
  const [playing, setPlaying] = useState(true);
  const [held, setHeld] = useState(false);
  const [seen, setSeen] = useState(false);
  const reduce = useMediaQuery(REDUCED_MOTION);
  const running = playing && !reduce && !held && seen;
  useEffect(() => {
    const el = section.current;
    if (!el || !("IntersectionObserver" in window)) return;
    const obs = new IntersectionObserver(([e]) => setSeen(e.isIntersecting), { threshold: 0.5 });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);
  useEffect(() => {
    if (!running) return;
    const timer = setTimeout(() => scrollToSlide(track.current, ends.end ? 0 : current + 1, true), DWELL);
    return () => clearTimeout(timer);
  }, [running, current, ends.end]);
  useEffect(() => {
    const el = track.current;
    if (!el) return;
    let frame = 0;
    const sync = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        setEnds({ start: el.scrollLeft < 8, end: el.scrollLeft + el.clientWidth > el.scrollWidth - 8 });
        const slide = el.querySelector(".slide");
        if (slide) setCurrent(Math.round(el.scrollLeft / (slide.getBoundingClientRect().width + 20)));
      });
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
  /** The reader steps the gallery: it stops moving on its own. */
  const pick = (i: number) => {
    setPlaying(false);
    scrollToSlide(track.current, i, !reduce);
  };
  const step = (dir: 1 | -1) => pick(current + dir);
  return (
    <section
      className="band"
      aria-labelledby="features-title"
      ref={section}
      onPointerEnter={() => setHeld(true)}
      onPointerLeave={() => setHeld(false)}
      onFocus={() => setHeld(true)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setHeld(false);
      }}
    >
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
      <div className="wrap car-dots">
        {/* hidden with reduced motion (landing.css), where the gallery never moves on its own */}
        <button type="button" className="car-play" aria-label={playing ? t.pause : t.play} onClick={() => setPlaying((p) => !p)}>
          <Icon name={playing ? "pause" : "play"} />
        </button>
        <div className={running ? "dots run" : "dots"}>
          {t.slides.map((s, i) => (
            <button key={s.title} type="button" aria-label={`${t.show} ${s.title}`} aria-current={i === current ? "true" : undefined} onClick={() => pick(i)}>
              {/* keyed by the slide, so the pill's fill starts over on each one */}
              <i key={i === current ? `on-${current}` : "off"} />
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}
