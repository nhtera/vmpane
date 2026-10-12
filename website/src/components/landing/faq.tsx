// SPDX-License-Identifier: Apache-2.0

import { Icon } from "@/components/site/icons";
import { FAQ } from "@/content/faq";
import { landing } from "@/content/landing";
import { RichText } from "./rich-text";

const t = landing.faq;

/** Questions as <details>: they open without JavaScript; the first one is open. */
export function FaqSection() {
  return (
    <section className="band" id="faq" aria-labelledby="faq-title">
      <div className="wrap">
        <div className="head">
          <h2 id="faq-title">
            {t.title[0]}
            <br />
            <span className="hl-blue">{t.title[1]}</span>
          </h2>
        </div>
        <div className="faq">
          {FAQ.map((f, i) => (
            <details key={f.q} open={i === 0}>
              <summary>
                {f.q}
                <Icon name="plus" />
              </summary>
              <p>
                <RichText text={f.a} />
              </p>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
