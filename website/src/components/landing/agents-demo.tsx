// SPDX-License-Identifier: Apache-2.0

import { type CSSProperties, useEffect, useRef, useState } from "react";
import { landing } from "@/content/landing";
import transcript from "@/content/demo-transcript.txt?raw";
import { AgentSession } from "./agent-session";
import { AgentsOrbit } from "./agents-orbit";
import { ActivityMock, SettingsMock } from "./mocks";
import { RichText } from "./rich-text";
import { TwoTone } from "./two-tone";

const t = landing.agents;

/**
 * The five access levels: a chip per level sets the VM's Settings › AI agents
 * (drawn in HTML) and its explanation (the app's own text); beside it, what
 * the same agent session leaves in the activity list at that level. While the
 * demo is on screen it steps through the levels on its own, until the reader
 * points at, focuses or picks a chip (not with reduced motion); only the
 * reader's own picks are announced. Then one real session, step by step.
 */
export function AgentsDemo() {
  const [level, setLevel] = useState<number>(t.defaultLevel);
  const [touched, setTouched] = useState(false);
  const demo = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = demo.current;
    if (touched || !el || matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return;
    let timer = 0;
    const obs = new IntersectionObserver(
      ([e]) => {
        clearInterval(timer);
        if (e.isIntersecting) timer = window.setInterval(() => setLevel((l) => (l + 1) % t.levels.length), 2800);
      },
      { threshold: 0.6 },
    );
    obs.observe(el);
    return () => {
      obs.disconnect();
      clearInterval(timer);
    };
  }, [touched]);
  const touch = () => setTouched(true);
  return (
    <section className="band" id="agents" aria-labelledby="agents-title">
      <div className="wrap">
        <div className="head split">
          <div className="head-copy">
            <h2 id="agents-title">
              <TwoTone text={t.title} />
            </h2>
            <p>
              <RichText text={t.lead[0]} />
              <b>{t.lead[1]}</b>
              {t.lead[2]}
            </p>
          </div>
          <AgentsOrbit />
        </div>
        <div className="media wall-a" ref={demo}>
          <div className="agents-demo">
            <SettingsMock level={level} />
            <ActivityMock level={level} />
          </div>
        </div>
        <p className="explain" aria-live={touched ? "polite" : "off"}>
          <b>{t.levels[level].title}.</b> {t.levels[level].explain}
        </p>
        <div className="lvls" role="group" aria-label={t.levelsLabel} onPointerEnter={touch} onFocus={touch}>
          {t.levels.map((l, i) => (
            <button key={l.chip} type="button" style={{ "--c": `var(--${l.c})` } as CSSProperties} aria-pressed={i === level} onClick={() => { touch(); setLevel(i); }}>
              {l.chip}
            </button>
          ))}
        </div>
        <AgentSession />
        <details className="transcript">
          <summary>{t.transcript.summary}</summary>
          <p>{t.transcript.note}</p>
          <pre tabIndex={0} role="region" aria-label={t.transcript.summary}>
            {transcript.split("\n").map((line, i) => (
              <span key={i} className={line.startsWith("→") ? "call" : line.startsWith("←") ? "reply" : line.startsWith("Claude:") ? "said" : undefined}>
                {line}
                {"\n"}
              </span>
            ))}
          </pre>
        </details>
      </div>
    </section>
  );
}
