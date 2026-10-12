// SPDX-License-Identifier: Apache-2.0

// The landing page's questions. Plain text, with `code` in backticks: the
// page renders them as <details> (backticks as <code>), and the structured
// data (FAQPage) reuses the same list without the backticks.

export interface Faq {
  q: string;
  a: string;
}

export const FAQ: readonly Faq[] = [
  {
    q: "Is VMPane free?",
    a: "Yes. It is open source under Apache-2.0. Windows needs your own licence; VMPane installs it from your ISO.",
  },
  {
    q: "Which Macs does it run on?",
    a: "Macs with Apple silicon, on macOS 15 or later.",
  },
  {
    q: "Can I run x86 Windows or Linux?",
    a: "No. VMPane runs Arm guests only, with no emulation. Windows 11 on Arm runs x64 apps through its own built-in emulation.",
  },
  {
    q: "Do I need a Microsoft account?",
    a: "No. Setup runs with no network, so Windows creates the local account you choose.",
  },
  {
    q: "How do AI agents connect?",
    a: "Run `vmpane mcp config claude` (or codex, gemini). The agent starts `vmpane mcp` and talks to it over stdin and stdout. Nothing listens on the network.",
  },
  {
    q: "Can an agent reach my Mac's files?",
    a: "Agents copy files only to and from `~/VMPane Exchange/<vm>/`. If a VM shares a folder and you let agents run commands, they can change that folder, and Settings tells you so.",
  },
  {
    q: "How does it update?",
    a: "VMPane checks for updates itself and asks before it installs one. With Homebrew, `brew upgrade` works too.",
  },
];

/** An answer as plain text (the structured data): backticks dropped. */
export const plainAnswer = (a: string) => a.replace(/`([^`]*)`/g, "$1");
