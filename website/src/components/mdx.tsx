// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import type { MDXComponents } from "mdx/types";
import { type ComponentProps, createContext, isValidElement, type ReactElement, type ReactNode, use } from "react";
import { CodeBlock } from "@/components/docs/code-block";
import { strings } from "@/content/strings";
import { parseDocsUrl } from "@/lib/docs-toc";
import { isKeyChord } from "@/lib/key-chord";

// Scrollable tables are keyboard-focusable named groups (the code block is its own).
const group = (label: string) => ({ role: "group", "aria-label": label, tabIndex: 0 });

// Inline code is a <kbd> when it is a key chord; code inside a block never is.
const InBlock = createContext(false);

type El = ReactElement<{ children?: ReactNode }>;
const elementChildren = (children: ReactNode): ReactNode[] => (Array.isArray(children) ? children : [children]).filter((c) => c !== "\n" && c !== "" && c != null);

// A step list: an ordered list whose items each start with a **bold** title
// (directly, or inside the first paragraph of a loose item).
function isStepList(children: ReactNode): boolean {
  const items = elementChildren(children).filter((c): c is El => isValidElement(c));
  if (items.length === 0) return false;
  return items.every((li) => {
    let first = elementChildren(li.props.children)[0];
    if (isValidElement<{ children?: ReactNode }>(first) && first.type === "p") first = elementChildren(first.props.children)[0];
    return isValidElement(first) && first.type === "strong";
  });
}

function Pre(props: ComponentProps<"pre">) {
  return (
    <InBlock value={true}>
      <CodeBlock {...props} />
    </InBlock>
  );
}

function Code({ children, ...props }: ComponentProps<"code">) {
  const inBlock = use(InBlock);
  if (!inBlock && typeof children === "string" && isKeyChord(children)) return <kbd>{children}</kbd>;
  return <code {...props}>{children}</code>;
}

function Table(props: ComponentProps<"table">) {
  return (
    <div className="table-scroll" {...group(strings.docs.tableLabel)}>
      <table {...props} />
    </div>
  );
}

function Ol({ children, className, ...props }: ComponentProps<"ol">) {
  return (
    <ol {...props} className={isStepList(children) ? `${className ?? ""} steps`.trim() : className}>
      {children}
    </ol>
  );
}

// Links to other docs pages navigate client-side; the rest are plain anchors.
function A({ href, children, ...props }: ComponentProps<"a">) {
  const docs = href ? parseDocsUrl(href) : null;
  return docs ? (
    <Link to="/docs/$" params={{ _splat: docs.splat }} hash={docs.hash} {...props}>
      {children}
    </Link>
  ) : (
    <a href={href} {...props}>
      {children}
    </a>
  );
}

// Blockquotes are callouts: styled by the `.article blockquote` rule.
// One stable map (not rebuilt per render, which would remount the article).
const base = { pre: Pre, code: Code, table: Table, ol: Ol, a: A } satisfies MDXComponents;

export function getMDXComponents(components?: MDXComponents): MDXComponents {
  return components ? { ...base, ...components } : base;
}
