// SPDX-License-Identifier: Apache-2.0

import { Icon } from "@/components/site/icons";
import { FAQ } from "@/content/faq";
import { landing } from "@/content/landing";
import { RichText } from "./rich-text";
import { TwoTone } from "./two-tone";

const t = landing.faq;

/** Questions as <details>: they open without JavaScript; the first one is open. */
export function FaqSection() {
  return (
    <section className="band" id="faq" aria-labelledby="faq-title">
      <div className="wrap">
        <div className="head">
          <h2 id="faq-title">
            <TwoTone text={t.title} />
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
