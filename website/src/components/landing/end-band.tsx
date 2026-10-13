// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import quickstart from "../../../content/generated/quickstart.json" with { type: "json" };
import { Icon } from "@/components/site/icons";
import { landing } from "@/content/landing";
import { strings } from "@/content/strings";
import { RELEASES_URL } from "@/lib/urls";
import { InstallMock, MacGuestMock, MenuMock, UnameMock } from "./mocks";

const t = landing.end;

/** The closing band: the app icon, one CTA, the docs, and the install command from README.md's Install section. */
export function EndBand() {
  return (
    <section className="end" aria-labelledby="end-title">
      <div className="collage" aria-hidden="true">
        <div className="tile wall-d" style={{ left: "6%", top: 90, transform: "rotate(-6deg)" }}>
          <MacGuestMock decorative />
        </div>
        <div className="tile wall-c" style={{ left: "12%", bottom: 80, transform: "rotate(5deg)" }}>
          <UnameMock />
        </div>
        <div className="tile wall-b" style={{ right: "6%", top: 110, transform: "rotate(7deg)" }}>
          <InstallMock compact />
        </div>
        <div className="tile wall-a" style={{ right: "12%", bottom: 70, transform: "rotate(-5deg)" }}>
          <MenuMock compact />
        </div>
      </div>
      <img className="app" src="/icon.svg" alt="" width="128" height="128" />
      <h2 id="end-title">
        {t.title[0]}
        <br />
        <span className="hl-blue">{t.title[1]}</span>
      </h2>
      <p>{t.body}</p>
      <div className="row">
        <a className="btn btn-dark" href={RELEASES_URL}>
          <Icon name="download" />
          {strings.nav.cta}
        </a>
        <Link className="btn btn-light" to="/docs/$" params={{ _splat: "" }}>
          <Icon name="book" />
          {t.docs}
        </Link>
      </div>
      <code className="brew">
        <span className="d">$</span> {quickstart.commands}
      </code>
    </section>
  );
}
