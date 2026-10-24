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

/**
 * The distance from one slide to the next (slides are 20 px apart). Layout width, not the drawn one: the slides
 * shrink as they leave the middle of the row (landing.css), and a shrunk first slide made every jump land short.
 */
function slideStep(el: HTMLElement) {
  const slide = el.querySelector<HTMLElement>(".slide");
  return slide ? slide.offsetWidth + 20 : 0;
}

/** Scroll the track to slide `i`. */
function scrollToSlide(el: HTMLElement | null, i: number, smooth: boolean) {
  if (!el) return;
  el.scrollTo({ left: i * slideStep(el), behavior: smooth ? "smooth" : "auto" });
}

/**
 * A scroll-snap track of features with Previous and Next. The track itself is
 * focusable (arrow keys scroll it); the buttons step one slide and turn off at
 * either end. The scroll listener only updates the buttons and the dots.
 * Under the track, a play/pause button and a dot per slide (the current one a
 * pill that fills): while the gallery is on screen it moves on each time the
 * pill fills (landing.css times it), back to the start after the last slide.
 * Pause, keyboard focus in it (not a click) and being off screen hold it: the
 * pill stops where it is and goes on from there. The pointer does not hold it:
 * the section fills the window, so a resting pointer stopped it for good. It
 * stops for good when the reader steps it, until Play, and never starts with
 * reduced motion.
 */
export function FeatureCarousel() {
  const track = useRef<HTMLDivElement>(null);
  const section = useRef<HTMLElement>(null);
  const [ends, setEnds] = useState({ start: true, end: false });
  const [current, setCurrent] = useState(0);
  const [playing, setPlaying] = useState(true);
  // the reader stepped it (a dot or an arrow): no more moving on, and no pill filling, until Play
  const [stepped, setStepped] = useState(false);
  const [held, setHeld] = useState(false);
  const [seen, setSeen] = useState(false);
  const reduce = useMediaQuery(REDUCED_MOTION);
  const auto = !reduce && (playing || !stepped);
  const moving = playing && !held && seen;
  useEffect(() => {
    const el = section.current;
    if (!el || !("IntersectionObserver" in window)) return;
    const obs = new IntersectionObserver(([e]) => setSeen(e.isIntersecting), { threshold: 0.5 });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);
  useEffect(() => {
    const el = track.current;
    if (!el) return;
    let frame = 0;
    const sync = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const end = el.scrollLeft + el.clientWidth > el.scrollWidth - 8;
        setEnds({ start: el.scrollLeft < 8, end });
        // at the end of the row the last slide is the current one, though it cannot scroll to the start
        const step = slideStep(el);
        if (step) setCurrent(end ? t.slides.length - 1 : Math.round(el.scrollLeft / step));
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
    setStepped(true);
    scrollToSlide(track.current, i, !reduce);
  };
  const step = (dir: 1 | -1) => pick(current + dir);
  return (
    <section
      className="band"
      aria-labelledby="features-title"
      ref={section}
      onFocus={(e) => setHeld(e.target.matches(":focus-visible"))}
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
        <button type="button" className="car-play" aria-label={playing ? t.pause : t.play} onClick={() => {
            setPlaying((p) => !p);
            setStepped(false);
          }}>
          <Icon name={playing ? "pause" : "play"} />
        </button>
        {/* the current pill fills while the gallery plays; when it is full, the next slide comes */}
        <div
          className={auto ? (moving ? "dots run" : "dots run held") : "dots"}
          onAnimationEnd={(e) => {
            if (moving && e.animationName === "pillfill") scrollToSlide(track.current, ends.end ? 0 : current + 1, true);
          }}
        >
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
