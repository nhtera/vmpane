// SPDX-License-Identifier: Apache-2.0

import { type ComponentProps, isValidElement, type ReactNode, useEffect, useRef, useState } from "react";
import { docsStrings } from "@/content/docs-strings";
import { strings } from "@/content/strings";

const LANG_LABEL: Record<string, string> = { sh: "Terminal", bash: "Terminal", shell: "Terminal", zsh: "Terminal", json: "JSON", yaml: "YAML", yml: "YAML", powershell: "PowerShell", ps1: "PowerShell", ts: "TypeScript", md: "Markdown" };

/** `language-sh` on the <code> child (rehype-code adds it) → `sh`. */
function languageOf(children: ReactNode): string | undefined {
  const code = Array.isArray(children) ? children[0] : children;
  if (!isValidElement<{ className?: string }>(code)) return undefined;
  return /(?:^|\s)language-([\w-]+)/.exec(code.props.className ?? "")?.[1];
}

type Status = "idle" | "copied" | "selected" | "failed";

/** A code block: a head row with the language and a Copy button, the code scrolling inside its own focusable group. */
export function CodeBlock({ children, ...props }: ComponentProps<"pre">) {
  const pre = useRef<HTMLPreElement>(null);
  const [status, setStatus] = useState<Status>("idle");
  const lang = languageOf(children);
  const label = (lang && LANG_LABEL[lang]) || strings.docs.codeLabel;

  useEffect(() => {
    if (status === "idle") return;
    const t = setTimeout(() => setStatus("idle"), 2000);
    return () => clearTimeout(t);
  }, [status]);

  const copy = async () => {
    const el = pre.current;
    if (!el) return;
    try {
      await navigator.clipboard.writeText(el.textContent ?? "");
      setStatus("copied");
    } catch {
      // No clipboard permission (or an old browser): select the code so Ctrl/⌘+C works.
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = window.getSelection();
      if (!selection) return setStatus("failed");
      selection.removeAllRanges();
      selection.addRange(range);
      setStatus("selected");
    }
  };

  const text = status === "copied" ? strings.docs.copied : status === "selected" ? strings.docs.selected : status === "failed" ? docsStrings.copyFailed : strings.docs.copy;

  return (
    <div className="code">
      <div className="code-head">
        <span>{label}</span>
        <button className="copy-btn" type="button" onClick={copy}>
          {text}
          <span className="sr-only"> {label}</span>
        </button>
        <span className="sr-only" role="status">
          {status === "idle" ? "" : text}
        </span>
      </div>
      <pre ref={pre} role="group" aria-label={label} tabIndex={0} className={props.className}>
        {children}
      </pre>
    </div>
  );
}
