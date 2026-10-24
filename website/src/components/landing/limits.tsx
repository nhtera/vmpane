// SPDX-License-Identifier: Apache-2.0

import { Icon, type IconName } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { TwoTone } from "./two-tone";

const t = landing.limits;
const r = landing.requirements;

/**
 * Good to know, before installing: what VMPane does not do, said plainly, beside what the new-VM sheet gives
 * each system and the least memory it needs (the app's own defaults) on a card. Side by side on wide screens.
 */
export function Limits() {
  return (
    <section className="band gray" aria-labelledby="limits-title">
      <div className="wrap">
        <div className="head">
          <h2 id="limits-title">
            <TwoTone text={t.title} />
          </h2>
        </div>
        <div className="know">
          <div>
            <h3>{t.heading}</h3>
            <div className="limits">
              {t.items.map((l) => (
                <div key={l.title}>
                  <Icon name={l.icon as IconName} />
                  <b>{l.title}</b>
                  <span>{l.body}</span>
                </div>
              ))}
            </div>
          </div>
          <div className="sizes">
            <h3>{r.heading}</h3>
            {/* Scrolls sideways on a phone: focusable, so the keyboard can scroll it too. */}
            <div className="scroll" tabIndex={0} role="region" aria-label={r.caption}>
              <table>
                <caption>{r.caption}</caption>
                <thead>
                  <tr>
                    {r.columns.map((c) => (
                      <th key={c} scope="col">
                        {c}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {r.rows.map(([system, ...cells]) => (
                    <tr key={system}>
                      <th scope="row">{system}</th>
                      {cells.map((c, i) => (
                        <td key={r.columns[i + 1]}>{c}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p>{r.note}</p>
          </div>
        </div>
      </div>
    </section>
  );
}
