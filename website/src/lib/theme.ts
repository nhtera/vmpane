// SPDX-License-Identifier: Apache-2.0

// Light, dark, or the OS setting. The theme follows the OS until the reader
// picks one with the toggle; the pick is stored in localStorage (the only
// thing the site stores). The init script runs in <head>
// before first paint, so the page never flashes the wrong theme; it is an
// inline script, allowed by its hash in the CSP (scripts/csp-headers.mjs).
// Without JavaScript the page is light.

export const THEME_KEY = "vmpane-site-theme";

export type Theme = "light" | "dark";

/** A stored value is used only when it is exactly "light" or "dark". */
export function validTheme(value: unknown): Theme | null {
  return value === "light" || value === "dark" ? value : null;
}

export const THEME_INIT_SCRIPT = `(function(){var d=document.documentElement,k=${JSON.stringify(THEME_KEY)};function s(){try{var v=localStorage.getItem(k);return v==="light"||v==="dark"?v:null}catch(e){return null}}var m=matchMedia("(prefers-color-scheme: dark)");d.dataset.theme=s()||(m.matches?"dark":"light");m.addEventListener("change",function(e){if(!s())d.dataset.theme=e.matches?"dark":"light"})})();`;

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

/** For useSyncExternalStore: calls back when data-theme changes (the toggle, or the OS while nothing is stored). */
export function subscribeTheme(onChange: () => void): () => void {
  const obs = new MutationObserver(onChange);
  obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  return () => obs.disconnect();
}
