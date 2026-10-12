// SPDX-License-Identifier: Apache-2.0

import { createContext, lazy, type ReactNode, Suspense, use, useCallback, useEffect, useRef, useState } from "react";
import { strings } from "@/content/strings";
import { Icon } from "@/components/site/icons";
import { SearchField } from "./search-field";

// The search code (zbsearch, the result list) and the index are downloaded on
// first open, not with the page.
const SearchPanel = lazy(() => import("./search-panel"));

const OpenSearch = createContext<() => void>(() => {});

/**
 * Owns the search `<dialog>` and the ⌘K / Ctrl+K shortcut. It is mounted by
 * the docs shell only, so the shortcut exists on docs routes and nowhere else.
 * `dialog.showModal()` makes the page inert and returns focus to the element
 * that had it (the trigger button) on close; Esc closes natively.
 */
export function DocsSearchProvider({ children }: { children: ReactNode }) {
  const dialog = useRef<HTMLDialogElement>(null);
  // 0 until first opened; every open remounts the panel with an empty query.
  const [session, setSession] = useState(0);
  // What was typed before the search code arrived.
  const [draft, setDraft] = useState("");

  const open = useCallback(() => {
    const d = dialog.current;
    if (!d || d.open) return;
    setSession((s) => s + 1);
    setDraft("");
    d.showModal();
  }, []);
  const close = useCallback(() => dialog.current?.close(), []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.altKey || e.shiftKey || !(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== "k") return;
      e.preventDefault();
      open();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <OpenSearch value={open}>
      {children}
      {/* A click on the backdrop lands on the dialog element itself. */}
      <dialog ref={dialog} className="search" aria-label={strings.docs.search} onClick={(e) => e.target === e.currentTarget && close()}>
        {session > 0 ? (
          <Suspense
            fallback={
              <>
                <SearchField autoFocus value={draft} onChange={(e) => setDraft(e.target.value)} />
                <p className="search-note" role="status">
                  {strings.docs.searchLoading}
                </p>
              </>
            }
          >
            <SearchPanel key={session} initial={draft} onClose={close} />
          </Suspense>
        ) : null}
      </dialog>
    </OpenSearch>
  );
}

/** The "Search docs ⌘K" button of the sidebar and the mobile docs menu. */
export function SearchButton() {
  const open = use(OpenSearch);
  return (
    <button className="search-btn" type="button" aria-haspopup="dialog" aria-keyshortcuts="Meta+K Control+K" onClick={open}>
      <Icon name="search" />
      {strings.docs.search}
      <kbd aria-hidden="true">{strings.docs.searchShortcut}</kbd>
    </button>
  );
}
