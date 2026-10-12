// SPDX-License-Identifier: Apache-2.0

import { strings } from "@/content/strings";
import { editUrl } from "@/lib/doc-paths";
import { formatDate } from "@/lib/docs-toc";

/** Edit on GitHub (from the validated source path) and the date of the last change. */
export function PageFooter({ source, lastUpdated }: { source: string; lastUpdated?: string }) {
  return (
    <p className="edit">
      <a href={editUrl(source)} rel="noreferrer noopener">
        {strings.docs.edit}
      </a>
      {lastUpdated ? (
        <span>
          {strings.docs.lastUpdated} <time dateTime={lastUpdated}>{formatDate(lastUpdated)}</time>
        </span>
      ) : null}
    </p>
  );
}
