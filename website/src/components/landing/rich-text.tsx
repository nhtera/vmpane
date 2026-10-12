// SPDX-License-Identifier: Apache-2.0

/** Copy with `code` in backticks: the code spans become <code>, the rest stays text (never HTML). */
export function RichText({ text }: { text: string }) {
  return (
    <>
      {text.split(/(`[^`]*`)/).map((part, i) =>
        part.startsWith("`") && part.endsWith("`") && part.length > 1 ? <code key={i}>{part.slice(1, -1)}</code> : part,
      )}
    </>
  );
}
