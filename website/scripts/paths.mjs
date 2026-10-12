// SPDX-License-Identifier: Apache-2.0

import { fileURLToPath } from "node:url";

/** website/ */
export const SITE_DIR = fileURLToPath(new URL("..", import.meta.url));

/** The Cloudflare Build Output the deploy uploads. */
export const BUILD_OUTPUT_DIR = fileURLToPath(new URL("../.cloudflare/output/v0", import.meta.url));

/** The static assets (every check runs on this directory). */
export const OUTPUT_DIR = fileURLToPath(new URL("../.cloudflare/output/v0/workers/default/assets", import.meta.url));

/** The Worker that is deployed. */
export const WORKER_DIR = fileURLToPath(new URL("../.cloudflare/output/v0/workers/default/bundle", import.meta.url));
