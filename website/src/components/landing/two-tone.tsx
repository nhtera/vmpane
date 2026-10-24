// SPDX-License-Identifier: Apache-2.0

/** A two-sentence headline: the statement, then its second sentence in grey (Apple's two-tone heading). */
export function TwoTone({ text }: { text: readonly [string, string] }) {
  return (
    <>
      {text[0]} <span className="tone">{text[1]}</span>
    </>
  );
}
