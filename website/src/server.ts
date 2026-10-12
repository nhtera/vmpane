// SPDX-License-Identifier: Apache-2.0

// The build's Worker, used in development and to prerender every page: it
// renders only for prerender requests (a per-build token header) and in
// development, and answers anything else like the deployed Worker. It is
// never deployed: scripts/build-worker.mjs replaces it with the 404-only
// src/worker/production.ts, which contains no render path and no token.
import handler from "@tanstack/react-start/server-entry";
import { notFound, type Env } from "./worker/not-found";

declare const __VMPANE_PRERENDER_TOKEN__: string;
// Set by vite.config.ts on every prerender request; not exported (Workers
// treat named exports as entrypoints).
const PRERENDER_HEADER = "x-vmpane-prerender";

// Workers module syntax: the runtime calls fetch(request, env, ctx), and
// TanStack's entry takes the same arguments.
const render = handler.fetch as unknown as (request: Request, env: Env, ctx: unknown) => Promise<Response>;

export default {
  async fetch(request: Request, env: Env, ctx: unknown): Promise<Response> {
    if (import.meta.env.DEV || request.headers.get(PRERENDER_HEADER) === __VMPANE_PRERENDER_TOKEN__) {
      return render(request, env, ctx);
    }
    return notFound(request, env);
  },
};
