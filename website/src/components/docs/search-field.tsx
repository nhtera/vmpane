// SPDX-License-Identifier: Apache-2.0

import type { ComponentProps, Ref } from "react";
import { Icon } from "@/components/site/icons";
import { docsStrings } from "@/content/docs-strings";
import { strings } from "@/content/strings";

/**
 * The search box. The dialog shows it before the search code has loaded, so
 * what is typed right after ⌘K is kept; the panel then takes it over with
 * the combobox attributes.
 */
export function SearchField({ ref, ...props }: ComponentProps<"input"> & { ref?: Ref<HTMLInputElement> }) {
  return (
    <div className="search-field">
      <Icon name="search" />
      <label className="sr-only" htmlFor="search-input">
        {strings.docs.search}
      </label>
      <input
        ref={ref}
        id="search-input"
        type="text"
        placeholder={docsStrings.searchPlaceholder}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        enterKeyHint="go"
        {...props}
      />
    </div>
  );
}
