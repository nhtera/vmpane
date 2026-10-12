// SPDX-License-Identifier: Apache-2.0

import { useSyncExternalStore } from "react";

export const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";
/** Below this width the notes' transcript panel is far below the notes. */
export const NARROW = "(max-width: 900px)";

/** Whether a media query matches. False on the server and while hydrating. */
export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const mq = matchMedia(query);
      mq.addEventListener("change", onChange);
      return () => mq.removeEventListener("change", onChange);
    },
    () => matchMedia(query).matches,
    () => false,
  );
}
