// SPDX-License-Identifier: Apache-2.0

// The Worker that is deployed (scripts/build-worker.mjs bundles this file in
// place of the build's Worker). It imports nothing from TanStack Start, so it
// cannot render a page on request: it only answers misses with 404.html.
import { notFound, type Env } from "./not-found";

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return notFound(request, env);
  },
};
