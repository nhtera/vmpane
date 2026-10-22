// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties } from "react";
import { Icon, type IconName } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { RichText } from "./rich-text";
import { MenuMock, SnapshotsMock } from "./mocks";

const t = landing.safety;

const Badge = ({ icon, c }: { icon: IconName; c: string }) => (
  <span className="badge" style={{ "--c": `var(--${c})` } as CSSProperties} aria-hidden="true">
    <Icon name={icon} />
  </span>
);

/**
 * Seven cells: the kill switch (menu capture), undo (snapshots capture), ask first, off by default, the record, take
 * over (the VM window's agent pill) and sign-in.
 */
export function SafetyBento() {
  return (
    <section className="band gray" aria-labelledby="safety-title">
      <div className="wrap">
        <div className="head">
          <h2 id="safety-title">
            {t.title[0]}
            <br />
            <span className="hl-green">{t.title[1]}</span>
          </h2>
        </div>
        <div className="bento">
          <div className="cell a">
            <Badge icon="stop" c="red" />
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
            <Badge icon="arrow-uturn" c="purple" />
            <h3>{t.undo.title}</h3>
            <p>{t.undo.body}</p>
            <SnapshotsMock />
          </div>
          <div className="cell c">
            <Badge icon="question" c="blue" />
            <h3>{t.ask.title}</h3>
            <p>{t.ask.body}</p>
            <div className="mini-ask" aria-hidden="true">
              <span>{t.ask.buttons[0]}</span>
              <span className="def">{t.ask.buttons[1]}</span>
            </div>
          </div>
          <div className="cell d">
            <Badge icon="lock" c="gray" />
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
            <Badge icon="list" c="teal" />
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
            <Badge icon="hand" c="orange" />
            <h3>{t.takeOver.title}</h3>
            <p>{t.takeOver.body}</p>
            <div className="mini-pill" aria-hidden="true">
              <span>{t.takeOver.pill[0]}</span>
              <span className="btn-like">{t.takeOver.pill[1]}</span>
              <span className="btn-like">{t.takeOver.pill[2]}</span>
            </div>
          </div>
          <div className="cell g">
            <Badge icon="shield" c="green" />
            <h3>{t.signIn.title}</h3>
            <p>{t.signIn.body}</p>
          </div>
        </div>
      </div>
    </section>
  );
}
