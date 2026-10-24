// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties } from "react";
import { Icon } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { RichText } from "./rich-text";
import { MenuMock, SnapshotsMock } from "./mocks";
import { TwoTone } from "./two-tone";

const t = landing.safety;

/**
 * Seven cells: the kill switch (menu capture), undo (snapshots capture), ask first, off by default, the record, take
 * over (the VM window's agent pill) and sign-in (the lock screen's password field, filled dot by dot as it scrolls in).
 */
export function SafetyBento() {
  return (
    <section className="band theme-dark" aria-labelledby="safety-title">
      <div className="wrap">
        <div className="head">
          <h2 id="safety-title">
            <TwoTone text={t.title} />
          </h2>
        </div>
        <div className="bento">
          <div className="cell a">
            <h3>{t.stop.title}</h3>
            <p>
              {t.stop.body[0]}
              {t.stop.keys.map((k) => (
                <kbd key={k}>{k}</kbd>
              ))}
              <RichText text={t.stop.body[2]} />
            </p>
            <div className="scene wall-b">
              <div className="mbar" aria-hidden="true">
                <span className="ico">
                  <img src="/favicon.svg" alt="" width="18" height="18" />
                </span>
                <span>{t.stop.clock}</span>
              </div>
              <MenuMock />
            </div>
          </div>
          <div className="cell b">
            <h3>{t.undo.title}</h3>
            <p>{t.undo.body}</p>
            <SnapshotsMock />
          </div>
          <div className="cell c">
            <h3>{t.ask.title}</h3>
            <p>{t.ask.body}</p>
            <div className="mini-ask" aria-hidden="true">
              <span>{t.ask.buttons[0]}</span>
              <span className="def">{t.ask.buttons[1]}</span>
            </div>
          </div>
          <div className="cell d">
            <h3>{t.off.title}</h3>
            <p>
              <RichText text={t.off.body} />
            </p>
            <div className="mini-pop" aria-hidden="true">
              <span>{t.off.popup[0]}</span>
              <b>
                {t.off.popup[1]}
                <Icon name="chevron-right" />
              </b>
            </div>
          </div>
          <div className="cell e">
            <h3>{t.record.title}</h3>
            <p>{t.record.body}</p>
            <pre className="json">
              {t.record.json[0]}
              {"\n"}
              {t.record.json[1]}
              {"\n"}
              {t.record.json[2]}
              <b>{t.record.json[3]}</b>
              {t.record.json[4]}
            </pre>
          </div>
          <div className="cell f">
            <h3>{t.takeOver.title}</h3>
            <p>{t.takeOver.body}</p>
            <div className="mini-pill" aria-hidden="true">
              <span>{t.takeOver.pill[0]}</span>
              <span className="btn-like">{t.takeOver.pill[1]}</span>
              <span className="btn-like">{t.takeOver.pill[2]}</span>
            </div>
          </div>
          <div className="cell g">
            <h3>{t.signIn.title}</h3>
            <p>{t.signIn.body}</p>
            <div className="mini-lock" aria-hidden="true">
              <Icon name="lock" />
              <span className="pw">
                {Array.from({ length: t.signIn.field.dots }, (_, i) => (
                  <i key={i} style={{ "--i": (i / (t.signIn.field.dots - 1)).toFixed(3) } as CSSProperties} />
                ))}
              </span>
              <span className="by">{t.signIn.field.by}</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
