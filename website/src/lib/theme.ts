// SPDX-License-Identifier: Apache-2.0

// Light or dark. The site opens light, whatever the OS setting, until the
// reader picks dark with the toggle; the pick is stored in localStorage (the
// only thing the site stores). The init script runs in <head> before first
// paint, so the page never flashes the wrong theme; it is an inline script,
// allowed by its hash in the CSP (scripts/csp-headers.mjs). Without
// JavaScript the page is light.

export const THEME_KEY = "vmpane-site-theme";

export type Theme = "light" | "dark";

/** A stored value is used only when it is exactly "light" or "dark". */
export function validTheme(value: unknown): Theme | null {
  return value === "light" || value === "dark" ? value : null;
}

export const THEME_INIT_SCRIPT = `(function(){var v;try{v=localStorage.getItem(${JSON.stringify(THEME_KEY)})}catch(e){}document.documentElement.dataset.theme=v==="dark"?"dark":"light"})();`;

export function currentTheme(): Theme {
  return validTheme(document.documentElement.dataset.theme) ?? "light";
}

export function setTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch {
    // Storage blocked (private mode): the choice lasts for this page only.
  }
}

/** For useSyncExternalStore: calls back when data-theme changes (the toggle). */
export function subscribeTheme(onChange: () => void): () => void {
  const obs = new MutationObserver(onChange);
  obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  return () => obs.disconnect();
}
