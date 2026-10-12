// SPDX-License-Identifier: Apache-2.0

import { createRouter } from "@tanstack/react-router";
import { NotFound } from "./components/not-found";
import { routeTree } from "./routeTree.gen";

export function getRouter() {
  return createRouter({
    routeTree,
    defaultPreload: "intent",
    scrollRestoration: true,
    defaultNotFoundComponent: NotFound,
  });
}
