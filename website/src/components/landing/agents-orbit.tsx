// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties } from "react";
import { landing } from "@/content/landing";

const t = landing.agents.orbit;

/**
 * VMPane's icon with `vmpane mcp` under it, and the clients that connect
 * through it circling on a ring (landing.css turns the ring; each name turns
 * back the other way, so it stays upright). Still under reduced motion.
 */
export function AgentsOrbit() {
  return (
    <div className="orbit" role="img" aria-label={t.label}>
      <span className="ring r1" />
      <span className="ring r2" />
      <span className="ring r3" />
      <div className="orbit-core">
        <img src="/icon.svg" alt="" width="88" height="88" />
        <code>{t.command}</code>
      </div>
      <div className="spin">
        {t.clients.map((c, i) => (
          <span key={c} className="sat" style={{ "--a": `${i * 120 - 90}deg` } as CSSProperties}>
            <span>{c}</span>
          </span>
        ))}
      </div>
    </div>
  );
}
