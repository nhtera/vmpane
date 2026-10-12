// SPDX-License-Identifier: Apache-2.0

import { docs } from "collections/server";
import { loader } from "fumadocs-core/source";
import { DOCS_BASE } from "./urls";

export const source = loader({
  baseUrl: DOCS_BASE,
  source: docs.toFumadocsSource(),
});
