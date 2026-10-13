// SPDX-License-Identifier: Apache-2.0

import { type CSSProperties, useState } from "react";
import { landing } from "@/content/landing";
import { RichText } from "./rich-text";
import { ActivityMock, SettingsMock } from "./mocks";

const t = landing.agents;

/**
 * The five access levels: a chip per level sets the VM's Settings › AI agents
 * (drawn in HTML) and its explanation (the app's own text, announced
 * politely); beside it, what the same agent session leaves in the activity
 * list at that level.
 */
export function AgentsDemo() {
  const [level, setLevel] = useState<number>(t.defaultLevel);
  return (
    <section className="band" id="agents" aria-labelledby="agents-title">
      <div className="wrap">
        <div className="head">
          <span className="eyebrow hl-orange">{t.eyebrow}</span>
          <h2 id="agents-title">
            {t.title[0]}
            <br />
            <span className="hl-orange">{t.title[1]}</span>
          </h2>
          <p>
            <RichText text={t.lead[0]} />
            <b>{t.lead[1]}</b>
            {t.lead[2]}
          </p>
        </div>
        <div className="media wall-a">
          <div className="agents-demo">
            <SettingsMock level={level} />
            <ActivityMock level={level} />
          </div>
        </div>
        <p className="explain" aria-live="polite">
          <b>{t.levels[level].title}.</b> {t.levels[level].explain}
        </p>
        <div className="lvls" role="group" aria-label={t.levelsLabel}>
          {t.levels.map((l, i) => (
            <button key={l.chip} type="button" style={{ "--c": `var(--${l.c})` } as CSSProperties} aria-pressed={i === level} onClick={() => setLevel(i)}>
              {l.chip}
            </button>
          ))}
        </div>
        <div className="demo-hand">
          <span className="hand">
            <svg viewBox="0 0 46 40" aria-hidden="true">
              <path d="M4 4c10 4 22 14 26 30M30 34l-8-4M30 34l3-9" />
            </svg>
            {t.hand}
          </span>
        </div>
      </div>
    </section>
  );
}
