// SPDX-License-Identifier: Apache-2.0

import { useNavigate } from "@tanstack/react-router";
import { useDocsSearch } from "fumadocs-core/search/client";
import { staticClient } from "fumadocs-core/search/client/orama-static";
import { type KeyboardEvent, type MouseEvent, useEffect, useMemo, useRef, useState } from "react";
import { docsStrings } from "@/content/docs-strings";
import { strings } from "@/content/strings";
import { SearchField } from "./search-field";
import { parseDocsUrl } from "@/lib/docs-toc";
import { groupResults, highlightSegments } from "@/lib/search-text";

// The prerendered index: a static file, downloaded on first query.
const client = staticClient({ from: "/api/search.json" });

/** Result text as React text nodes; matches in <mark>. Never HTML. */
function Highlighted({ text }: { text: string }) {
  return highlightSegments(text).map((s, i) => (s.mark ? <mark key={i}>{s.text}</mark> : s.text));
}

const plain = (text: string) =>
  highlightSegments(text)
    .map((s) => s.text)
    .join("");

interface Option {
  id: string;
  url: string;
  kind: "page" | "heading" | "text";
  content: string;
  section?: string;
}

export default function SearchPanel({ initial, onClose }: { initial: string; onClose: () => void }) {
  const { search, setSearch, query } = useDocsSearch({ client });
  // Start from what was typed while this code was loading.
  const [seeded, setSeeded] = useState(false);
  if (!seeded) {
    setSeeded(true);
    if (initial) setSearch(initial);
  }
  const navigate = useNavigate();
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);

  const rows = useMemo(() => {
    let n = 0;
    const next = () => `search-opt-${n++}`;
    return (Array.isArray(query.data) ? groupResults(query.data) : []).map((g) => ({
      id: g.id,
      label: plain(g.title),
      options: [
        { id: next(), url: g.url, kind: "page", content: g.title, section: g.section },
        ...g.hits.map((h): Option => ({ id: next(), url: h.url, kind: h.type === "heading" ? "heading" : "text", content: h.content })),
      ] as Option[],
    }));
  }, [query.data]);
  const options = useMemo(() => rows.flatMap((r) => r.options), [rows]);

  // The highlighted option resets to the first whenever the results change.
  const [state, setState] = useState<{ data: unknown; index: number }>({ data: query.data, index: 0 });
  const active = state.data === query.data ? Math.min(state.index, Math.max(options.length - 1, 0)) : 0;
  const activeId = options[active]?.id;

  // The field above replaced the loading one: take focus, caret after the text.
  useEffect(() => {
    const el = input.current;
    if (!el) return;
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  }, []);
  useEffect(() => {
    if (activeId) list.current?.querySelector(`#${activeId}`)?.scrollIntoView({ block: "nearest" });
  }, [activeId]);

  const go = (url: string) => {
    const parts = parseDocsUrl(url);
    if (!parts) return;
    onClose();
    void navigate({ to: "/docs/$", params: { _splat: parts.splat }, hash: parts.hash });
  };

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (options.length === 0) return;
    const move = (index: number) => {
      e.preventDefault();
      setState({ data: query.data, index });
    };
    if (e.key === "ArrowDown") move((active + 1) % options.length);
    else if (e.key === "ArrowUp") move((active - 1 + options.length) % options.length);
    else if (e.key === "Home" && e.ctrlKey) move(0);
    else if (e.key === "End" && e.ctrlKey) move(options.length - 1);
    else if (e.key === "Enter" && !e.nativeEvent.isComposing) {
      e.preventDefault();
      go(options[active].url);
    }
  };

  const onClick = (e: MouseEvent<HTMLAnchorElement>, url: string) => {
    // New tab / window gestures keep the browser's behaviour.
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    go(url);
  };

  const term = search.trim();
  const failed = query.error !== undefined;
  const empty = !failed && !query.isLoading && term !== "" && Array.isArray(query.data) && options.length === 0;
  const note = failed
    ? strings.docs.searchError
    : empty
      ? strings.docs.searchEmpty(term)
      : query.isLoading && options.length === 0
        ? strings.docs.searchLoading
        : term === ""
          ? docsStrings.searchHint
          : "";
  const status = note || (options.length > 0 ? docsStrings.searchStatus(options.length) : "");

  return (
    <>
      <SearchField
        ref={input}
        role="combobox"
        aria-expanded={options.length > 0}
        aria-controls="search-results"
        aria-activedescendant={activeId}
        aria-autocomplete="list"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        onKeyDown={onKeyDown}
      />
      <div className="results" id="search-results" role="listbox" aria-label={docsStrings.searchResults} ref={list}>
        {rows.map((r) => (
          <div key={r.id} role="group" aria-label={r.label}>
            {r.options.map((o) => (
              <a
                key={o.id}
                id={o.id}
                role="option"
                aria-selected={o.id === activeId}
                className={o.kind === "page" ? "result result-page" : "result result-hit"}
                href={o.url}
                tabIndex={-1}
                onClick={(e) => onClick(e, o.url)}
              >
                <span>
                  <Highlighted text={o.content} />
                </span>
                {o.section ? <small>{o.section}</small> : null}
              </a>
            ))}
          </div>
        ))}
      </div>
      {note ? <p className="search-note">{note}</p> : null}
      <p className="sr-only" role="status">
        {status}
      </p>
    </>
  );
}
