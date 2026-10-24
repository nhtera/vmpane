// SPDX-License-Identifier: Apache-2.0

import type { CSSProperties, ReactNode } from "react";
import { Icon, type IconName } from "@/components/site/icons";
import { landing } from "@/content/landing";

/*
 * VMPane's windows drawn in HTML (design draft v5), in the app's own words
 * (landing.mock). Every size inside a window is in em, so a window scales
 * with its font size: .w sets it per place (the story's Mac screen, a tile, a
 * slide). Colours come from tokens.css (--win-*), so the windows follow the
 * page's light or dark look. A picture is one image to a screen reader (its
 * `label`); the agents demo's activity list is real, readable text.
 */

const m = landing.mock;

export function Lights() {
  return (
    <span className="lights">
      <i />
      <i />
      <i />
    </span>
  );
}

/** A window: title bar (traffic lights, title, toolbar icons) and its content. */
export function Win({
  title,
  tools,
  className,
  style,
  label,
  children,
}: {
  title?: string;
  tools?: ReactNode;
  className?: string;
  style?: CSSProperties;
  /** What the picture shows, for a screen reader; none (or a decorative copy): hidden from it. */
  label?: string;
  children: ReactNode;
}) {
  const a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": true };
  return (
    <div className={className ? `w ${className}` : "w"} style={style} {...a11y}>
      <div className="bar">
        <Lights />
        {title && <b>{title}</b>}
        {tools && <span className="tools">{tools}</span>}
      </div>
      {children}
    </div>
  );
}

const tools = (names: IconName[]) => names.map((n) => <Icon key={n} name={n} />);

/** A macOS switch, on or off. */
const Switch = ({ on }: { on: boolean }) => <span className={on ? "sw" : "sw off"} />;

// ---------- the story: the library, the VM's window, the agent's question ----------

/** A system's tile, as the app draws it: a letter, four panes (Windows) or a laptop (macOS), in its colours. */
export function Tile({ v }: { v: (typeof m.vms)[number] }) {
  return (
    <span className={`tile ${v.brand}`}>
      {v.tile === "panes" ? <span className="panes"><i /><i /><i /><i /></span> : v.tile === "mac" ? <Icon name="laptopcomputer" /> : v.tile}
    </span>
  );
}

export function LibraryMock({ className }: { className?: string }) {
  // Newest first, as the app lists them: the denied command on top.
  const [denied, allowed] = activity(4);
  const chosen = m.vms[0];
  return (
    <div className={className ? `w lib ${className}` : "w lib"} role="img" aria-label={m.library.label}>
      <div className="side">
        <div className="side-top">
          <Lights />
        </div>
        {m.library.filters.map(([title, count, icon, c], i) => (
          <div key={title} className={i === 0 ? "row sel" : "row"}>
            <span className="ico" style={{ "--c": `var(--${c})` } as CSSProperties}>
              <Icon name={icon as IconName} />
            </span>
            <span className="nm">
              <b>{title}</b>
            </span>
            <span className="sz">{count}</span>
          </div>
        ))}
      </div>
      <div className="main">
        <div className="bar">
          <b>{m.library.filters[0][0]}</b>
          <span className="tools">{tools(["import", "list", "plus"])}</span>
        </div>
        <div className="vms">
          {m.vms.map((v, i) => (
            <div key={v.name} className={i === 0 ? "vm sel" : "vm"}>
              <Tile v={v} />
              <span className="nm">
                <b>{v.name}</b>
                <span className={`sd ${v.st}`}>
                  {v.state} · {v.os}
                </span>
                <small>{v.spec}</small>
              </span>
            </div>
          ))}
        </div>
      </div>
      <div className="insp">
        <div className="ihead">
          <Tile v={chosen} />
          <span className="nm">
            <b>{chosen.name}</b>
            <span className={`sd ${chosen.st}`}>{chosen.state}</span>
          </span>
        </div>
        <div className="group">
          {m.library.facts.map(([k, v]) => (
            <div className="li" key={k}>
              <span>{k}</span>
              <span>{v}</span>
            </div>
          ))}
        </div>
        <div className="gh">{m.library.activity}</div>
        <div className="group act">
          <ActivityRow row={denied} className="s-row" />
          <ActivityRow row={allowed} />
        </div>
      </div>
    </div>
  );
}

export function TermMock({ className, children }: { className?: string; children?: ReactNode }) {
  const t = m.term;
  return (
    <Win className={className} title={m.vm} tools={<VmTools />} label={t.label}>
      <div className="term">
        <span className="g">{t.prompt}</span>:<span className="b">~</span>$ {t.command}
        {"\n"}
        <span className="d">{t.out[0]}</span>
        {"\n"}
        {t.out.slice(1).join("\n")}
      </div>
      {children}
    </Win>
  );
}

/** The VM window's toolbar: power, snapshots, settings, screenshot, and the guest agent's status. */
const VmTools = () => (
  <>
    {tools(["power", "clock-arrow", "sliders", "viewfinder"])}
    <Icon name="bolt-circle" className="ok" />
  </>
);

/** ConfirmationDialog: the agent's command in a box, Deny as the default button. */
export function AlertMock({ className, children }: { className?: string; children?: ReactNode }) {
  const a = m.alert;
  const [allow, deny] = landing.safety.ask.buttons;
  return (
    <div className={className ? `alert ${className}` : "alert"} role="img" aria-label={a.label}>
      <img className="app" src="/icon.svg" alt="" width="64" height="64" />
      <b>{a.title}</b>
      <span>{a.info}</span>
      <code>{a.command}</code>
      <div className="btns">
        <span>{allow}</span>
        <span className="def s-deny">{deny}</span>
      </div>
      {children}
    </div>
  );
}

// ---------- the agents demo: Settings › AI agents and the activity, at a level ----------

export interface Activity {
  method: string;
  ok: boolean;
  detail: string;
}

/**
 * What the demo session leaves in the activity list at `level` (0-4), as the
 * helper records it, newest first (AuditLog.recent): allowed calls, calls the
 * level refuses (the policy's own reason), and the administrator command the
 * person denied. At Off agents cannot see the VM, so nothing reaches it.
 */
export function activity(level: number): Activity[] {
  if (level === 0) return [];
  const rows = m.session.map((c) => {
    if (level < c.need)
      return { method: c.method, ok: false, detail: `${c.time} · ${c.method} needs policy level ${m.levels[c.need]}; this VM allows ${m.levels[level]}` };
    if ("asked" in c && c.asked) return { method: c.method, ok: false, detail: `${c.time} · ${m.personSaidNo} (${m.alert.title})` };
    return { method: c.method, ok: true, detail: c.time };
  });
  return rows.reverse();
}

function ActivityRow({ row, className }: { row: Activity; className?: string }) {
  return (
    <div className={className ? `li ${className}` : "li"}>
      <Icon name={row.ok ? "checkmark-circle" : "hand"} className={row.ok ? "ok" : "den"} />
      <div>
        <span className="sr-only">{row.ok ? m.allowed : m.refused}: </span>
        {m.client}: {row.method}
        <small>{row.detail}</small>
      </div>
    </div>
  );
}

export function SettingsMock({ level }: { level: number }) {
  const levels = landing.agents.levels;
  return (
    <Win title={`${m.settings.title} · ${m.vm}`}>
      <div className="sets">
        <div className="secs">
          {m.settings.sections.map(([title, icon, c]) => (
            <div key={title} className={title === m.settings.section ? "sec sel" : "sec"}>
              <span className="ico" style={{ "--c": `var(--${c})` } as CSSProperties}>
                <Icon name={icon as IconName} />
              </span>
              {title}
            </div>
          ))}
        </div>
        <div className="body">
          <div className="gh">{m.settings.levels}</div>
          <div className="group">
            {levels.map((lv, i) => (
              <div className="formrow" key={lv.title}>
                <span className={i === level ? "rad on" : "rad"}>{lv.title}</span>
                <span className={i === level ? "rd on" : "rd"} />
              </div>
            ))}
          </div>
          {level > 0 && (
            <div className="group">
              {m.toggles.map((t) => (
                <div className="formrow" key={t.label}>
                  <span>{t.label}</span>
                  <Switch on={t.on} />
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </Win>
  );
}

/** The activity list: real text, so the demo's outcome is readable without the picture. */
export function ActivityMock({ level }: { level: number }) {
  const rows = activity(level);
  return (
    <div className="w">
      <div className="bar" aria-hidden="true">
        <Lights />
        <b>{m.vm}</b>
      </div>
      <div className="body">
        <h3 className="gh">{m.library.activity}</h3>
        {/* keyed by level: a new level mounts new rows, and they slide in (landing.css) */}
        <div className="group act" key={level}>
          {rows.length === 0 ? (
            <div className="li empty">{m.noActivity}</div>
          ) : (
            rows.map((r, i) => <ActivityRow key={i} row={r} />)
          )}
        </div>
      </div>
    </div>
  );
}

// ---------- safety and features ----------

/** The menu bar menu; `compact` (a decorative tile) keeps only Stop All AI Agents. */
export function MenuMock({ className, compact = false }: { className?: string; compact?: boolean }) {
  const t = m.menu;
  const a11y = compact ? { "aria-hidden": true } : { role: "img", "aria-label": t.label };
  return (
    <div className={className ? `menu ${className}` : "menu"} {...a11y}>
      {!compact && (
        <>
          {t.vms.map((v) => (
            <div key={v}>
              {v}
              <Icon name="chevron-right" />
            </div>
          ))}
          <div className="sep" />
        </>
      )}
      <div className="hot">
        {t.stop[0]} <span>{t.stop[1]}</span>
      </div>
      {!compact && (
        <>
          <div className="sep" />
          {t.items.map((i) => (
            <div key={i}>{i}</div>
          ))}
          <div>
            {t.quit[0]} <span>{t.quit[1]}</span>
          </div>
        </>
      )}
    </div>
  );
}

export function SnapshotsMock({ className }: { className?: string }) {
  const t = m.snapshots;
  return (
    <Win className={className} title={t.title} label={t.label}>
      <div className="body">
        <div className="btns">
          <span className="pill ghost">{t.take}</span>
        </div>
        <div className="group">
          {t.rows.map((r, i) => (
            <div className={i === 0 ? "li snap sel" : "li snap"} key={r.name}>
              <Icon name={"ram" in r && r.ram ? "cpu" : "square-stack"} />
              <span className="nm">
                <span>{r.name}</span>
                <small>
                  {r.date}
                  {"agent" in r && r.agent && ` · ${t.agent}`}
                  {"ram" in r && r.ram && <span className="tag ram">{t.ram}</span>}
                </small>
              </span>
              <small>{r.size}</small>
            </div>
          ))}
        </div>
        <div className="btns">
          <span className="pill ghost">{t.buttons[0]}</span>
          <span className="pill ghost">{t.buttons[1]}</span>
          <span className="pill">{t.buttons[2]}</span>
        </div>
      </div>
    </Win>
  );
}

export function PortsMock({ className }: { className?: string }) {
  const t = m.ports;
  return (
    <Win className={className} title={t.title} label={t.label}>
      <div className="body">
        <div className="group">
          {t.rules.map((r) => (
            <div className="li" key={r}>
              <span className="mono">
                <i className="dot" />
                {r}
              </span>
              <Icon name="minus-circle" />
            </div>
          ))}
        </div>
        <div className="gh">{t.listening}</div>
        <div className="group">
          <div className="li">
            <span className="mono">{t.open[0]}</span>
            <span className="link">{t.open[1]}</span>
          </div>
        </div>
        <div className="btns">
          <span className="pill ghost">{t.add}</span>
        </div>
      </div>
    </Win>
  );
}

export function SharingMock({ className }: { className?: string }) {
  const t = m.sharing;
  return (
    <Win className={className} title={t.title} label={t.label}>
      <div className="body">
        <div className="group">
          {t.shares.map((s) => (
            <div className="li" key={s.path}>
              <span className="path">
                <Icon name="folder" />
                {s.path}
              </span>
              <span className="check">
                <i className={s.readOnly ? "on" : undefined} />
                {t.readOnly}
              </span>
            </div>
          ))}
        </div>
        <div className="btns">
          <span className="pill ghost">{t.add}</span>
        </div>
      </div>
    </Win>
  );
}

export function ImportMock({ className }: { className?: string }) {
  const t = m.import;
  return (
    <Win className={className} title={t.title} label={t.label}>
      <div className="body">
        <div className="group">
          {t.facts.map(([k, v]) => (
            <div className="li" key={k}>
              <span>{k}</span>
              <span className="popup">{v}</span>
            </div>
          ))}
        </div>
        <div className="sm">{t.note}</div>
        <div className="btns">
          <span className="pill ghost">{t.buttons[0]}</span>
          <span className="pill">{t.buttons[1]}</span>
        </div>
      </div>
    </Win>
  );
}

export function ClipboardMock({ className }: { className?: string }) {
  const t = m.clipboard;
  return (
    <Win className={className} title={`${t.title} · ${m.vm}`} label={t.label}>
      <div className="body">
        <div className="group">
          {t.rows.map(([k, v]) => (
            <div className="li" key={k}>
              <span>{k}</span>
              <span className="popup">{v}</span>
            </div>
          ))}
          {t.toggles.map((s) => (
            <div className="li" key={s.label}>
              <span>{s.label}</span>
              <Switch on={s.on} />
            </div>
          ))}
        </div>
      </div>
    </Win>
  );
}

// ---------- the guests ----------

/** A macOS guest's desktop: Finder's menu bar and a Terminal window (its lines type in while the tab shows). */
export function MacGuestMock({ className, decorative = false }: { className?: string; decorative?: boolean }) {
  return (
    <Win className={className} title={m.macos.name} label={decorative ? undefined : m.macos.label}>
      <div className="desk">
        <div className="desk-bar">
          <b>{m.macos.menubar[0]}</b>
          {m.macos.menubar.slice(1).map((s) => (
            <span key={s}>{s}</span>
          ))}
        </div>
        <Win className="desk-term" title={m.macos.terminal}>
          <div className="term">
            {m.macos.lines.map(([p, text], i) => (
              <span key={i}>
                {p ? <span className="d">{p}</span> : null}
                {text}
                {"\n"}
              </span>
            ))}
          </div>
        </Win>
      </div>
    </Win>
  );
}

/** A Linux terminal with the library's thumbnail lines (`uname -m`): a decorative tile. */
export function UnameMock({ className }: { className?: string }) {
  return (
    <Win className={className} title={m.vm}>
      <div className="term">{m.library.thumb.join("\n")}</div>
    </Win>
  );
}

export function SharesMock({ className }: { className?: string }) {
  return (
    <Win className={className} title={m.vm} tools={<VmTools />} label={m.shares.label}>
      <div className="term">
        {m.shares.lines.map(([p, text], i) => (
          <span key={i}>
            {p ? (
              <>
                <span className="g">{m.term.prompt}</span>:<span className="b">~</span>
                {p}
              </>
            ) : null}
            {text}
            {"\n"}
          </span>
        ))}
      </div>
    </Win>
  );
}

/** The Windows install overlay; `compact` (a decorative tile) keeps the title and the progress bar. */
export function InstallMock({ className, compact = false }: { className?: string; compact?: boolean }) {
  const t = m.install;
  return (
    <Win className={className} title={t.name} label={compact ? undefined : t.label}>
      <div className="install">
        <div className="panel">
          <b>{t.title}</b>
          <span className="progress">
            <i style={{ width: `${t.percent}%` }} />
          </span>
          {!compact && (
            <>
              <span>{t.message}</span>
              <small>{t.note}</small>
            </>
          )}
        </div>
      </div>
    </Win>
  );
}
