// SPDX-License-Identifier: Apache-2.0

// Inline code that is a keyboard shortcut (`⌘⇧R`, `Ctrl+K`) renders as <kbd>.
// A chord has at least one modifier, so a plain `K` or `Esc` stays code.
const KEY = String.raw`(?:[A-Za-z0-9]|F\d{1,2}|Esc|Tab|Space|Enter|Return|Delete|Backspace|Up|Down|Left|Right|[,.;/\\\[\]'=-])`;
const MODIFIER_WORD = String.raw`(?:Ctrl|Control|Alt|Option|Shift|Cmd|Command|Win|Meta)`;
const SYMBOLS = new RegExp(String.raw`^[⌘⇧⌥⌃]+(?:${KEY})?$`);
const WORDS = new RegExp(String.raw`^(?:${MODIFIER_WORD}\+)+${KEY}$`);

export function isKeyChord(text: string): boolean {
  return SYMBOLS.test(text) || WORDS.test(text);
}
