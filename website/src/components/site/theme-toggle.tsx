// SPDX-License-Identifier: Apache-2.0

import { useSyncExternalStore } from "react";
import { strings } from "@/content/strings";
import { currentTheme, setTheme, subscribeTheme, type Theme } from "@/lib/theme";
import { Icon } from "./icons";

/**
 * Switches between light and dark and remembers the pick. Both icons are in
 * the markup; CSS shows the one for the current data-theme, so the button is
 * right before hydration. The label follows the theme once hydrated (the
 * server cannot know it, so it renders the light-theme label).
 */
export function ThemeToggle({ className = "icon-btn theme-btn", labelled = false }: { className?: string; labelled?: boolean }) {
  const theme = useSyncExternalStore<Theme>(subscribeTheme, currentTheme, () => "light");
  const label = theme === "dark" ? strings.theme.toLight : strings.theme.toDark;
  return (
    <button className={className} type="button" aria-label={labelled ? undefined : label} onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>
      <Icon name="moon" className="theme-moon" />
      <Icon name="sun" className="theme-sun" />
      {labelled ? label : null}
    </button>
  );
}
