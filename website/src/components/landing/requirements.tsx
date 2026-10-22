// SPDX-License-Identifier: Apache-2.0

import { landing } from "@/content/landing";

const t = landing.requirements;

/** What the new-VM sheet gives each system, and the least memory it needs: the app's own defaults. */
export function Requirements() {
  return (
    <section className="band" aria-labelledby="sizes-title">
      <div className="wrap">
        <div className="head">
          <span className="eyebrow">{t.eyebrow}</span>
          <h2 id="sizes-title">
            {t.title[0]}
            <br />
            <span className="hl-blue">{t.title[1]}</span>
          </h2>
        </div>
        <div className="sizes">
          {/* Scrolls sideways on a phone: focusable, so the keyboard can scroll it too. */}
          <div className="scroll" tabIndex={0} role="region" aria-label={t.caption}>
            <table>
              <caption>{t.caption}</caption>
              <thead>
                <tr>
                  {t.columns.map((c) => (
                    <th key={c} scope="col">
                      {c}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {t.rows.map(([system, ...cells]) => (
                  <tr key={system}>
                    <th scope="row">{system}</th>
                    {cells.map((c, i) => (
                      <td key={t.columns[i + 1]}>{c}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p>{t.note}</p>
        </div>
      </div>
    </section>
  );
}
