// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties } from "react";
import { landing } from "@/content/landing";

const t = landing.statement;
const words = t.text.split(" ");

/**
 * One large sentence under the Mac. As it scrolls into view its words light up
 * in reading order, grey to full colour (landing.css: each word's --i is its
 * place, 0 to 1). The grey is AA, and without scroll timelines or with reduced
 * motion every word simply shows in full colour.
 */
export function Statement() {
  return (
    <section className="band statement" aria-label={t.label}>
      <div className="wrap">
        <p className="say">
          {words.map((w, i) => (
            <span key={i} style={{ "--i": (i / (words.length - 1)).toFixed(3) } as CSSProperties}>
              {w}{" "}
            </span>
          ))}
        </p>
      </div>
    </section>
  );
}
