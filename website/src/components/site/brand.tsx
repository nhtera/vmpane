// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import { strings } from "@/content/strings";

/** The app icon (public/icon.svg, from Config/AppIcon.svg) and the name. Links home. */
export function Brand() {
  return (
    <Link className="logo" to="/" aria-label={strings.nav.home}>
      <img src="/icon.svg" alt="" width="28" height="28" />
      {strings.site.name}
    </Link>
  );
}
