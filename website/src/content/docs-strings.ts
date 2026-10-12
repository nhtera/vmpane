// SPDX-License-Identifier: Apache-2.0

// Copy for the docs chrome that strings.ts does not carry. English only.
export const docsStrings = {
  searchPlaceholder: "Search docs",
  searchResults: "Search results",
  searchHint: "Type to search titles, headings and text.",
  searchStatus: (n: number) => (n === 1 ? "1 result" : `${n} results`),
  sidebar: "Docs",
  copyFailed: "Copy failed",
} as const;
