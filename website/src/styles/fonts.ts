// SPDX-License-Identifier: Apache-2.0

// The one web font (Caveat, OFL-1.1) for the hero's handwritten note. It is
// preloaded so first paint uses it. The same file the @font-face rule points
// at, so Vite emits one asset: no double download.
import caveat600 from "../../node_modules/@fontsource/caveat/files/caveat-latin-600-normal.woff2?url";

export const fontPreloads = [caveat600].map((href) => ({
  rel: "preload",
  href,
  as: "font",
  type: "font/woff2",
  crossOrigin: "anonymous" as const,
}));
