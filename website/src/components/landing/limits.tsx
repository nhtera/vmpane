// SPDX-License-Identifier: Apache-2.0

import { Icon, type IconName } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { TwoTone } from "./two-tone";

const t = landing.limits;

/** What VMPane does not do, said plainly. */
export function Limits() {
  return (
    <section className="band gray" aria-labelledby="limits-title">
      <div className="wrap">
        <div className="head">
          <h2 id="limits-title">
            <TwoTone text={t.title} />
          </h2>
        </div>
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
    </section>
  );
}
