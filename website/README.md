# VMPane website

The landing page and the docs at https://vmpane.erai.dev. TanStack Start (Vite 8) with `fumadocs-core` +
`fumadocs-mdx` for the docs, VMPane's own native-Mac design (design draft v5), built with the
Cloudflare Vite plugin and the `cf` CLI. Every page is prerendered to HTML; a tiny Worker answers only the requests
no file matches (the 404 page) and cannot render a page.

The pipeline (scripts, `src/lib`, routes, tests) is ported from Ghira's site (`GhiApp/apps/website`, same owner,
Apache-2.0), which runs it in production at ghira.app. Ghira's look, copy and assets are not reused.

## Run it

Node 22.18 or later (`.nvmrc`). The site is a standalone npm project with its own lockfile, outside every Xcode
and Swift build (see Isolation).

```sh
cd website
npm ci --ignore-scripts
npm run dev           # http://localhost:3100
npm run build:site    # sync + cf build + finalize; output in .cloudflare/output/v0/
npm run preview       # the built site, served by the Workers runtime
npm test              # unit tests
npm run lint
npm run typecheck
npm run check         # build:site + check-links + the browser suites (needs: npx playwright install chromium)
```

## Where the content comes from

- **Docs:** `docs/README.md` is the nav. Each `## Section` heading is followed by a table of pages
  (`| [Title](file.md) | Contents |`), in sidebar order. Only table rows under a `##` heading are published; a
  file that is not listed is not published (default-deny). Besides `docs/*.md`, the guest guides in
  `docs/guides/` and three root documents (`../SECURITY.md`, `../CONTRIBUTING.md`, `../CODE_OF_CONDUCT.md`) may
  be listed. Any other folder (`docs/adr/`) or root file fails the build.
- `npm run sync` (`scripts/sync-docs.mjs`) copies the published docs into `content/` (generated, git-ignored) with
  frontmatter (title from the H1, description from the nav row, `source` for the Edit link, `lastUpdated` from
  git unless `VMPANE_SITE_NO_DATES=1`), and writes `content/generated/{nav,quickstart,inputs}.json`. It lists the
  docs it did not publish.
- **The install command** has one source: the single `sh` block under README.md `## Install`
  (`brew install --cask nhtera/tap/vmpane`). A `<!-- quickstart -->` line in a doc (`docs/install.md`) is
  replaced with it.
- **Links** in docs are rewritten at build time (`src/lib/remark-vmpane-links.ts`): a published doc becomes its
  site URL, any other repository file its GitHub page; only `https:` and `mailto:` schemes; a missing target, an
  image or another scheme fails the build; raw HTML is dropped.
- **Site links to docs** go through the published nav (`src/lib/site-links.ts`): a page that is not published
  yet links to `/docs`.
- **Look:** `src/styles/tokens.css` is the only file with colours (draft v5's tokens: Apple's marketing neutrals
  and the macOS system colours, light and dark; a test fails on a colour anywhere else). Text uses the system font
  (SF Pro on Apple devices); there is no web font. The logo, `public/icon.svg`, is `Config/AppIcon.svg` cropped to its square (a test keeps
  them in step); `public/favicon.svg` is its small-size variant and `public/apple-touch-icon.png` is rendered
  from it with `rsvg-convert`. `public/og.png` is captured from `/og-card` by `npm run og`. Copy lives in
  `src/content/*.ts`.

## The app's windows

The landing page draws VMPane's windows in HTML, as design draft v5 does (`src/components/landing/mocks.tsx`):
the library, a VM's window, the agent's question, Settings › AI agents, the activity list, the menu bar menu,
snapshots, port forwarding, shared folders, the Parallels import and the Windows install. Their text is the app's
own (`landing.mock` in `src/content/landing.ts`: state labels, the dialog, the policy's refusal reasons, port rule
and snapshot names), so a change to those strings in the app is a change here too. Their colours are tokens
(`--win-*` and friends), so they follow the light or dark look; each one is a labelled picture to a screen reader,
and the agents demo's activity list is real text.

## Isolation

`website/` has its own `package-lock.json` and is installed with `npm ci --ignore-scripts`; nothing in the app's
build (`project.yml`, `scripts/build.sh`, the Swift packages) knows it. So the beta Cloudflare tooling and its
install scripts never reach the app's build, including the release job that holds the signing secrets.
`npm run check:install-scripts` fails on any package with an install script that is not on its allowlist;
`.github/workflows/site.yml` runs it and `npm audit --audit-level=high` for both lockfiles (the site and
`deploy/`). `npm run check:licenses` fails on a shipped package whose licence is not allowed.

## Pipeline notes

Pinned as Ghira's (2026-10-09): `@tanstack/react-start` 1.168.60, `@cloudflare/vite-plugin`
2.0.0-beta.sha-52b0dc0e9, `cf` 1.0.0-beta.12, `fumadocs-core` 16.16.2, `fumadocs-mdx` 15.4.6, `vite` 8.3.2,
TypeScript 5.9.3. Do not upgrade them casually: `cf` is an open beta.

- **Prerender:** `cf build` prerenders `/`, `/docs`, every docs page, `/404.html` and the JSON/text routes listed
  in `vite.config.ts` `pages` (crawl + `failOnError`). Output: `.cloudflare/output/v0/` (`workers/default/assets/`
  = the static site, `workers/default/bundle/` = the Worker; `scripts/paths.mjs` names them).
- **The deployed Worker cannot render.** The build's Worker (`src/server.ts`) renders only for prerender requests
  carrying a per-build token (`VMPANE_PRERENDER_TOKEN`). It is never deployed: `npm run finalize` rebuilds the
  bundle from `src/worker/production.ts`, which imports nothing from TanStack Start, and
  `scripts/build-worker.mjs` fails if the bundle has anything but `index.js`, any TanStack/Fumadocs code or the
  token header.
- **CSP:** `scripts/csp-headers.mjs` writes `_headers` with a Content-Security-Policy per page that allows inline
  scripts only by hash (no `'unsafe-inline'` for scripts).
- **Search index budget on the gzip size** (`src/lib/search-index.ts`, 250 KB gzipped); it loads on the first
  search only.
- **Markdown, not MDX.** fumadocs-mdx compiles `.md` as Markdown: `{…}` is text, raw HTML is dropped
  (`test/fixtures/hostile.md`).

## Deploy

`.github/workflows/site.yml` builds and checks every change to the site's inputs; its deploy job stays off until
the repository variable `SITE_DEPLOY` is `1`.
