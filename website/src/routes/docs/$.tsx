// SPDX-License-Identifier: Apache-2.0

import { createFileRoute } from "@tanstack/react-router";
import browserCollections from "collections/browser";
import { Suspense } from "react";
import { DocsArticle, DocsShell } from "@/components/docs/docs-shell";
import { Toc } from "@/components/docs/toc";
import { getMDXComponents } from "@/components/mdx";
import { strings } from "@/content/strings";
import { loadDocsPage } from "@/lib/docs-data";
import { pageHead } from "@/lib/seo";
import { doc } from "@/lib/urls";

export const Route = createFileRoute("/docs/$")({
  component: Page,
  loader: async ({ params }) => {
    const slugs = params._splat?.split("/").filter(Boolean) ?? [];
    const data = await loadDocsPage(slugs);
    await clientLoader.preload(data.path);
    return { ...data, slug: slugs.join("/") };
  },
  head: ({ loaderData }) =>
    loaderData
      ? pageHead({
          title: loaderData.slug ? `${loaderData.title}${strings.docs.titleSuffix}` : `${loaderData.title} · VMPane`,
          description: loaderData.description,
          path: doc(loaderData.slug),
        })
      : {},
});

// The article and the table of contents are siblings in the shell's grid.
const clientLoader = browserCollections.docs.createClientLoader({
  component({ toc, frontmatter, default: MDX }, { slug }: { slug: string }) {
    return (
      <>
        <DocsArticle slug={slug} title={frontmatter.title} description={frontmatter.description} source={frontmatter.source} lastUpdated={frontmatter.lastUpdated}>
          <MDX components={getMDXComponents()} />
        </DocsArticle>
        <Toc key={slug} items={toc} />
      </>
    );
  },
});

function Page() {
  const { path, slug } = Route.useLoaderData();
  return (
    <DocsShell slug={slug}>
      <Suspense>{clientLoader.useContent(path, { slug })}</Suspense>
    </DocsShell>
  );
}
