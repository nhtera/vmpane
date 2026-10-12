// SPDX-License-Identifier: Apache-2.0

import { Link } from "@tanstack/react-router";
import { nav } from "@/lib/site-links";

/** The /docs index: each nav section with a card per page (title and nav description). */
export function IndexCards() {
  return (
    <>
      {nav.sections.map((section) => (
        <section key={section.title} aria-labelledby={`sec-${section.title}`.replace(/\W+/g, "-")}>
          <h2 id={`sec-${section.title}`.replace(/\W+/g, "-")}>{section.title}</h2>
          <ul className="cards">
            {section.pages.map((page) => (
              <li key={page.slug}>
                <Link to="/docs/$" params={{ _splat: page.slug }}>
                  <strong>{page.title}</strong>
                  <span>{page.description}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}
