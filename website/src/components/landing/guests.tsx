// SPDX-License-Identifier: Apache-2.0

import { type KeyboardEvent, type ReactNode, useRef, useState } from "react";
import { Icon, type IconName } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { InstallMock, MacGuestMock, SharesMock } from "./mocks";

const t = landing.guests;
const MEDIA: Record<string, { scene: ReactNode; wall: string }> = {
  mac: { scene: <MacGuestMock />, wall: "wall-d" },
  lin: { scene: <SharesMock />, wall: "wall-c" },
  win: { scene: <InstallMock />, wall: "wall-b" },
};

/**
 * Three guests as tabs (a native segmented control): click, or arrow keys
 * move between tabs with focus (roving tabindex). The panels are in the
 * markup from the start; the hidden ones fade out with CSS.
 */
export function Guests() {
  const [active, setActive] = useState(0);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const onKey = (e: KeyboardEvent, i: number) => {
    const n = t.tabs.length;
    const next = e.key === "ArrowRight" ? (i + 1) % n : e.key === "ArrowLeft" ? (i + n - 1) % n : e.key === "Home" ? 0 : e.key === "End" ? n - 1 : -1;
    if (next < 0) return;
    e.preventDefault();
    setActive(next);
    tabs.current[next]?.focus();
  };
  return (
    <section className="band" id="guests" aria-labelledby="guests-title">
      <div className="wrap">
        <div className="head">
          <h2 id="guests-title">
            {t.title[0]}
            <br />
            <span className="hl-blue">{t.title[1]}</span>
          </h2>
        </div>
        <div className="guests">
          <div className="gcopy">
            <div className="tabs" role="tablist" aria-label={t.label}>
              {t.tabs.map((g, i) => (
                <button
                  key={g.id}
                  ref={(el) => {
                    tabs.current[i] = el;
                  }}
                  type="button"
                  role="tab"
                  id={`t-${g.id}`}
                  aria-controls={`p-${g.id}`}
                  aria-selected={i === active}
                  tabIndex={i === active ? 0 : -1}
                  onClick={() => setActive(i)}
                  onKeyDown={(e) => onKey(e, i)}
                >
                  <Icon name={g.icon as IconName} />
                  {g.tab}
                </button>
              ))}
            </div>
            <div className="stack">
              {t.tabs.map((g, i) => (
                <div key={g.id} id={`p-${g.id}`} role="tabpanel" aria-labelledby={`t-${g.id}`} hidden={i !== active}>
                  <h3>{g.title}</h3>
                  <ul className="facts">
                    {g.facts.map((f) => (
                      <li key={f.text} className={"dim" in f && f.dim ? "dim" : undefined}>
                        <Icon name={"dim" in f && f.dim ? "info" : "checkmark-circle"} />
                        {f.text}
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          </div>
          <div className="stack">
            {t.tabs.map((g, i) => (
              <div key={g.id} className={`media big ${MEDIA[g.id].wall}`} hidden={i !== active}>
                {MEDIA[g.id].scene}
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
