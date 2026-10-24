// SPDX-License-Identifier: Apache-2.0

import { strings } from "@/content/strings";
import { docLink, rootDocLink } from "@/lib/site-links";
import { RELEASES_URL, REPO_URL } from "@/lib/urls";
import { Brand } from "./brand";

const t = strings.footer;

/** The footer: the logo and what VMPane is, three link columns, the licence line. */
export function SiteFooter() {
  return (
    <footer className="foot">
      <div className="wrap">
        <div className="cols">
          <div className="foot-brand">
            <Brand />
            <p>{t.about}</p>
          </div>
          <div>
            <h2>{t.product.title}</h2>
            <ul>
              {t.product.links.map((l) => (
                <li key={l.hash}>
                  <a href={`/#${l.hash}`}>{l.label}</a>
                </li>
              ))}
              <li>
                <a href={RELEASES_URL}>{t.product.download}</a>
              </li>
            </ul>
          </div>
          <div>
            <h2>{t.docs.title}</h2>
            <ul>
              {t.docs.links.map((l) => (
                <li key={l.slug}>
                  <a href={docLink(l.slug)}>{l.label}</a>
                </li>
              ))}
            </ul>
          </div>
          <div>
            <h2>{t.project.title}</h2>
            <ul>
              <li>
                <a href={REPO_URL}>{t.project.source}</a>
              </li>
              <li>
                <a href={rootDocLink(t.project.security.slug, t.project.security.file)}>{t.project.security.label}</a>
              </li>
              <li>
                <a href="/llms.txt">{t.project.llms}</a>
              </li>
            </ul>
          </div>
        </div>
        <div className="legal">
          {t.legal.map((s) => (
            <span key={s}>{s}</span>
          ))}
        </div>
      </div>
    </footer>
  );
}
