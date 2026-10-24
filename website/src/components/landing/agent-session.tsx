// SPDX-License-Identifier: Apache-2.0

import { useEffect, useRef, useState } from "react";
import { landing } from "@/content/landing";
import { Tile, Win } from "./mocks";
import { RichText } from "./rich-text";
import { TwoTone } from "./two-tone";

const t = landing.session;
const m = landing.mock;
// The library's tiles for the session's three VMs, in the session's order.
const TILES = [m.vms[2], m.vms[0], m.vms[1]];
// How the transcript marks each kind of line.
const PREFIX: Record<string, string> = { ask: "> ", call: "→ ", reply: "← ", said: "Claude: ", done: "" };

/**
 * One real Claude Code session, step by step. The steps scroll on the left;
 * on wide screens the transcript stays pinned beside them and grows to the
 * step in the middle of the screen, with the library's three VMs below it
 * showing where the session is. One observer picks the step. Each step also
 * carries its own lines: on phones, without JavaScript and for screen readers
 * they are the transcript (the pinned copy is hidden from screen readers).
 */
export function AgentSession() {
  const [active, setActive] = useState(0);
  const steps = useRef<(HTMLLIElement | null)[]>([]);
  useEffect(() => {
    if (!("IntersectionObserver" in window)) return;
    const obs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) if (e.isIntersecting) setActive(Number((e.target as HTMLElement).dataset.k));
      },
      { rootMargin: "-50% 0px -50% 0px" },
    );
    for (const el of steps.current) if (el) obs.observe(el);
    return () => obs.disconnect();
  }, []);
  const now = t.steps[active];
  return (
    <div className="sess">
      <h3 className="sess-title">
        <TwoTone text={t.title} />
      </h3>
      <div className="sess-grid">
        <ol className="sess-steps" aria-label={t.label}>
          {t.steps.map((s, i) => (
            <li
              key={s.title}
              data-k={i}
              ref={(el) => {
                steps.current[i] = el;
              }}
              className={i === active ? "on" : undefined}
            >
              <span className="k">{String(i + 1).padStart(2, "0")}</span>
              <b>{s.title}</b>
              <span>
                <RichText text={s.body} />
              </span>
              <pre className="sess-inline">
                {s.lines.map(([kind, text], j) => (
                  <span key={j} className={kind}>
                    {PREFIX[kind]}
                    {text}
                    {"\n"}
                  </span>
                ))}
              </pre>
            </li>
          ))}
        </ol>
        <div className="sess-stage" aria-hidden="true">
          <Win className="sess-term" title={t.window}>
            <div className="sess-out">
              {t.steps.slice(0, active + 1).flatMap((s, i) =>
                s.lines.map(([kind, text], j) => (
                  // the newest step's lines arrive one after another
                  <span key={`${i}-${j}`} className={kind} style={i === active ? { animationDelay: `${j * 140}ms` } : undefined}>
                    {PREFIX[kind]}
                    {text}
                  </span>
                )),
              )}
            </div>
          </Win>
          <Win className="sess-lib" title={t.library}>
            <div className="group">
              {t.vms.map((name, i) => (
                <div className="li" key={name}>
                  <Tile v={TILES[i]} />
                  <b>{name}</b>
                  <span className={now.state[i] === "Running" ? "sd run" : "sd"}>{now.state[i]}</span>
                  {"pass" in now && now.pass[i] ? <span className="tag pass">{t.pass}</span> : null}
                </div>
              ))}
            </div>
            {"snap" in now && now.snap ? (
              <small className="snapnote">
                {t.snapshotLabel} “{t.snapshot}”
              </small>
            ) : null}
          </Win>
        </div>
      </div>
    </div>
  );
}
