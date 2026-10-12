// SPDX-License-Identifier: Apache-2.0

import type { TOCItemType } from "fumadocs-core/toc";
import { useEffect, useState } from "react";
import { strings } from "@/content/strings";

/**
 * h2/h3 of the page; the heading in view is marked `aria-current="true"`.
 * At the bottom of the page the last heading is the current one, even when
 * the page cannot scroll it up to the top. Hidden on narrow screens by CSS.
 */
export function Toc({ items }: { items: TOCItemType[] }) {
  const entries = items.filter((i) => i.depth >= 2 && i.depth <= 3 && i.url.startsWith("#"));
  const [active, setActive] = useState<string>();
  const key = entries.map((e) => e.url).join(" ");

  useEffect(() => {
    const ids = key ? key.split(" ").map((u) => u.slice(1)) : [];
    const heads = ids.map((id) => document.getElementById(id)).filter((el): el is HTMLElement => el !== null);
    if (heads.length === 0) return;
    const obs = new IntersectionObserver(
      (list) => {
        const hit = list.find((en) => en.isIntersecting);
        if (hit) setActive(hit.target.id);
      },
      { rootMargin: "-80px 0px -70% 0px" },
    );
    for (const h of heads) obs.observe(h);
    let frame = 0;
    const onScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const root = document.documentElement;
        if (window.scrollY > 0 && window.innerHeight + window.scrollY >= root.scrollHeight - 2) setActive(heads[heads.length - 1].id);
      });
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      obs.disconnect();
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", onScroll);
    };
  }, [key]);

  if (entries.length === 0) return null;
  return (
    <nav className="toc" aria-label={strings.docs.toc}>
      <p>{strings.docs.toc}</p>
      {entries.map((e) => (
        <a key={e.url} href={e.url} data-depth={e.depth} aria-current={active === e.url.slice(1) ? "true" : undefined}>
          {e.title}
        </a>
      ))}
    </nav>
  );
}
