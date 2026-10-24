// SPDX-License-Identifier: Apache-2.0

// The site's icon set: the design draft's UI icons, redrawn at SF Symbols'
// weight (SF Symbols are licensed for app UI only, so the site never uses
// them). 24×24 strokes in currentColor, as inline SVG: no icon font, no
// network. Decorative: every icon is aria-hidden; the text next to it is the
// label.

import type { ReactNode } from "react";

const ICONS = {
  laptopcomputer: <><rect x="4" y="5" width="16" height="11" rx="1.6"/><path d="M2 19h20"/></>,
  terminal: <><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M7.5 9.5l3 2.5-3 2.5M12.5 15h4"/></>,
  pc: <><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/></>,
  macwindow: <><rect x="3" y="4.5" width="18" height="15" rx="3"/><path d="M3 9h18"/></>,
  power: <><path d="M12 3.5v8"/><path d="M7 6.3a7.5 7.5 0 1010 0"/></>,
  play: <><path d="M8 5.5v13l10.5-6.5z"/></>,
  pause: <><path d="M9 6v12M15 6v12"/></>,
  "clock-arrow": <><path d="M4.5 12a7.5 7.5 0 102.2-5.3L4.5 9"/><path d="M4.5 4.5V9H9M12 8v4.2l2.8 1.8"/></>,
  sliders: <><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/></>,
  viewfinder: <><path d="M4 8.5v-2A2.5 2.5 0 016.5 4h2M15.5 4h2A2.5 2.5 0 0120 6.5v2M20 15.5v2a2.5 2.5 0 01-2.5 2.5h-2M8.5 20h-2A2.5 2.5 0 014 17.5v-2"/><circle cx="12" cy="12" r="3"/></>,
  command: <><path d="M9 9V6.5A2.5 2.5 0 106.5 9H9zm0 0h6m-6 0v6m6-6V6.5A2.5 2.5 0 1117.5 9H15zm0 0v6m0 0h-6m6 0v2.5a2.5 2.5 0 102.5-2.5H15zm-6 0v2.5A2.5 2.5 0 116.5 15H9z"/></>,
  "bolt-circle": <><circle cx="12" cy="12" r="8.5"/><path d="M13 7l-4 5.5h4l-2 4.5 4-5.5h-4z"/></>,
  shield: <><path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z"/><path d="M9 12l2.2 2.2L15.5 10"/></>,
  hand: <><path d="M8 12V5.5a1.5 1.5 0 013 0V11m0-6.5a1.5 1.5 0 013 0V11m0-5a1.5 1.5 0 013 0v7.5c0 4-2.6 7-6.5 7-2.6 0-4.3-1.3-5.6-3.4L4 13.6a1.5 1.5 0 012.5-1.6L8 14"/></>,
  "checkmark-circle": <><circle cx="12" cy="12" r="8.5"/><path d="M8.3 12.3l2.5 2.5 5-5"/></>,
  "xmark-circle": <><circle cx="12" cy="12" r="8.5"/><path d="M9 9l6 6M15 9l-6 6"/></>,
  question: <><path d="M4 5.5h16v11h-9l-5 3.5v-3.5H4z"/><path d="M10 9.3a2 2 0 113 1.7c-.6.4-1 .8-1 1.4M12 14.3v.01"/></>,
  "square-stack": <><rect x="4" y="8" width="12" height="12" rx="2.5"/><path d="M8 5h9.5A2.5 2.5 0 0120 7.5V17"/></>,
  "arrow-uturn": <><path d="M9 14L4.5 9.5 9 5"/><path d="M4.5 9.5H14a5.5 5.5 0 010 11h-3"/></>,
  stop: <><path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2z"/><path d="M9 12h6"/></>,
  list: <><path d="M9 6.5h11M9 12h11M9 17.5h11"/><circle cx="4.75" cy="6.5" r=".9"/><circle cx="4.75" cy="12" r=".9"/><circle cx="4.75" cy="17.5" r=".9"/></>,
  network: <><rect x="3" y="8.5" width="6" height="7" rx="1.5"/><path d="M9 12h11.5M17 8.5l3.5 3.5-3.5 3.5"/></>,
  folder: <><path d="M3 7.5A2.5 2.5 0 015.5 5H9l2 2h7.5A2.5 2.5 0 0121 9.5v7a2.5 2.5 0 01-2.5 2.5h-13A2.5 2.5 0 013 16.5z"/></>,
  clipboard: <><rect x="5" y="4.5" width="14" height="16.5" rx="2.5"/><rect x="9" y="3" width="6" height="3" rx="1.2"/></>,
  cpu: <><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3"/><rect x="10" y="10" width="4" height="4" rx=".8"/></>,
  download: <><path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14"/></>,
  import: <><path d="M8 9H6.5A2.5 2.5 0 004 11.5v6A2.5 2.5 0 006.5 20h11a2.5 2.5 0 002.5-2.5v-6A2.5 2.5 0 0017.5 9H16"/><path d="M12 3.5v11M8.5 11l3.5 3.5 3.5-3.5"/></>,
  "line-3": <><path d="M4 7h16M4 12h16M4 17h16"/></>,
  plus: <><path d="M12 5v14M5 12h14"/></>,
  search: <><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/></>,
  book: <><path d="M4 5.5A1.5 1.5 0 015.5 4H11v16H5.5A1.5 1.5 0 014 18.5zM20 5.5A1.5 1.5 0 0018.5 4H13v16h5.5a1.5 1.5 0 001.5-1.5z"/></>,
  cursor: <><path d="M6 3.5v14.5l3.8-3.6 2.6 5.6 2.4-1.1-2.6-5.5H17z"/></>,
  sparkle: <><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/></>,
  lock: <><rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 018 0v3"/></>,
  "arrow-right": <><path d="M5 12h14M13 6l6 6-6 6"/></>,
  "chevron-left": <><path d="M15 5l-7 7 7 7"/></>,
  "chevron-right": <><path d="M9 5l7 7-7 7"/></>,
  info: <><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.01"/></>,
  warn: <><path d="M10.3 4.2a2 2 0 013.4 0l7.2 12.8a2 2 0 01-1.7 3H4.8a2 2 0 01-1.7-3z"/><path d="M12 9.5v4M12 16.8v.01"/></>,
  copy: <><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0013.5 4h-7A2.5 2.5 0 004 6.5v7A2.5 2.5 0 006.5 16H8"/></>,
  code: <><path d="M8 7.5L3.5 12 8 16.5M16 7.5l4.5 4.5-4.5 4.5M13.5 5l-3 14"/></>,
  "minus-circle": <><circle cx="12" cy="12" r="8.5"/><path d="M8.5 12h7"/></>,
  moon: <path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z" />,
  sun: (
    <>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
    </>
  ),
} satisfies Record<string, ReactNode>;

export type IconName = keyof typeof ICONS;

export function Icon({ name, className }: { name: IconName; className?: string }) {
  return (
    <svg className={className ? `i ${className}` : "i"} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {ICONS[name]}
    </svg>
  );
}
