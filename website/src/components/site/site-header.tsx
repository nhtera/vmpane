// SPDX-License-Identifier: Apache-2.0

import { Link, useRouterState } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { strings } from "@/content/strings";
import { RELEASES_URL, REPO_URL } from "@/lib/urls";
import { Brand } from "./brand";
import { Icon } from "./icons";
import { ThemeToggle } from "./theme-toggle";

const t = strings.nav;

/**
 * The floating glass pill. On phones (≤ 760 px) the links fold into a menu
 * button: the card drops below the pill without moving the page, and closes
 * on a link, a tap outside or Esc (which returns focus to the button). The
 * links follow the button in the markup, so Tab goes from it into the open
 * menu, and focus leaving the menu closes it. On phones the theme switch is
 * the menu's last row; on desktop the button is hidden, the switch sits in
 * the pill and the tab order is the visual one. Without JavaScript the
 * phone shows the links as a row instead (site.css).
 * In-page links are plain anchors; CSS scrolls them smoothly (unless the
 * reader asks for reduced motion) and lands each section below the pill.
 */
export function SiteHeader() {
  const [open, setOpen] = useState(false);
  const nav = useRef<HTMLElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const inDocs = useRouterState({ select: (s) => s.location.pathname.startsWith("/docs") });

  useEffect(() => {
    if (!open) return;
    const onPointer = (e: PointerEvent) => {
      if (!nav.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      setOpen(false);
      button.current?.focus();
    };
    document.addEventListener("pointerdown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onPointer);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const close = () => setOpen(false);
  return (
    <>
      <a className="skip" href="#main">
        {t.skip}
      </a>
      <header
        className={open ? "nav open" : "nav"}
        ref={nav}
        onBlur={(e) => {
          if (open && !nav.current?.contains(e.relatedTarget as Node | null)) setOpen(false);
        }}
      >
        <div className="nav-in">
          <Brand />
          <button
            className="icon-btn menu-btn"
            type="button"
            ref={button}
            aria-expanded={open}
            aria-controls="navlinks"
            aria-label={t.menu}
            onClick={() => setOpen((o) => !o)}
          >
            <Icon name="line-3" />
          </button>
          <nav className="nav-links" id="navlinks" aria-label={t.label}>
            {/* Plain anchors: a router Link would mark "/#x" as the current page on "/". */}
            {t.links.map((l) => (
              <a key={l.hash} href={`/#${l.hash}`} onClick={close}>
                {l.label}
              </a>
            ))}
            <Link to="/docs/$" params={{ _splat: "" }} aria-current={inDocs ? "page" : undefined} onClick={close}>
              {t.docs}
            </Link>
            <a href={REPO_URL} onClick={close}>
              {t.github}
            </a>
            <a className="nav-dl" href={RELEASES_URL} onClick={close}>
              <Icon name="download" />
              {t.cta}
            </a>
            <ThemeToggle className="nav-theme" labelled />
          </nav>
          <ThemeToggle />
          <a className="btn btn-dark btn-sm" href={RELEASES_URL}>
            <Icon name="download" />
            {t.cta}
          </a>
        </div>
      </header>
    </>
  );
}
