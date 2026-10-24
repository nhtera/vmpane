// SPDX-License-Identifier: Apache-2.0

import { landing } from "@/content/landing";
import { AlertMock, LibraryMock, TermMock } from "./mocks";
import { RichText } from "./rich-text";

const t = landing.story;

/**
 * The MacBook story: right under the hero, a tall section whose stage stays
 * pinned under the nav while four beats play on the scroll:
 * the library rises out of the Dock, the VM's window, the agent's typed
 * request, the approval dialog with the cursor on Deny, and the denied row in
 * the activity, in HTML windows (mocks.tsx). On wide screens a camera (.cam)
 * moves in on the window each step is about, so its text is read at a
 * readable size; on phones the Mac pans instead. All of it is CSS
 * scroll-driven animation (landing.css); without scroll timelines, or with
 * reduced motion, the final frame shows and the four steps sit in a row.
 */
export function MacStory() {
  return (
    <section className="story" id="story" aria-label={t.label}>
      <div className="story-track">
        <div className="story-stage">
          <div className="mac">
            <div className="mac-lid">
              <div className="screen wall-a">
                <div className="menubar" aria-hidden="true">
                  <b>{t.menubar[0]}</b>
                  {t.menubar.slice(1).map((m) => (
                    <span key={m}>{m}</span>
                  ))}
                  <span className="r">{t.clock}</span>
                </div>
                <div className="notch" />
                <div className="cam">
                  <LibraryMock className="s-lib" />
                  <TermMock className="s-vm" />
                  <p className="s-typed" aria-hidden="true">
                    <span className="y">{t.typed.agent}</span> <span className="d">{t.typed.verb}</span> {t.typed.command}
                  </p>
                  <AlertMock className="s-alert">
                    <svg className="cursor s-cursor" viewBox="0 0 24 24" aria-hidden="true">
                      <path d="M5 2.5v16l4.2-3.9 2.8 6.1 2.6-1.2-2.8-6H18z" />
                    </svg>
                  </AlertMock>
                  <div className="dock" aria-hidden="true">
                    <i />
                    <i />
                    <img className="on" src="/icon.svg" alt="" width="42" height="42" />
                    <i />
                    <i />
                  </div>
                </div>
              </div>
            </div>
            <div className="mac-base" />
          </div>
          <ol className="steps">
            {t.steps.map((s) => (
              <li key={s.title}>
                <b>{s.title}</b>
                <span>
                  <RichText text={s.body} />
                </span>
              </li>
            ))}
          </ol>
          <div className="story-bar" aria-hidden="true">
            <i />
          </div>
        </div>
      </div>
    </section>
  );
}
