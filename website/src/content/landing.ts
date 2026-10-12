// SPDX-License-Identifier: Apache-2.0

// The landing page's copy, English only (design draft v5). Every claim maps to
// shipped behaviour and uses the app's own strings: the access levels and
// their explanations are AgentPolicySection's, the dialog is the agent
// approval prompt's, the menu items are the menu bar menu's. `code` in
// backticks renders as <code>.

export type Tint = "blue" | "orange" | "green" | "purple" | "red";

export const landing = {
  hero: {
    meta: ["Free and open source", "macOS 15 or later", "Apple silicon"],
    title: ["Three systems.", "One Mac."],
    sub: "Run macOS, Linux and Windows 11 in native Mac windows. Lend one to an AI agent, within limits you set.",
    note: "Public beta soon",
  },
  story: {
    label: "How VMPane feels: a VM on your Mac and an agent asking first",
    title: ["Native windows.", "Your rules."],
    menubar: ["VMPane", "File", "Edit", "View", "Window", "Help"],
    clock: "Mon Oct 12 9:41 PM",
    typed: { agent: "claude-code", verb: "wants to run", command: "sudo apt upgrade -y" },
    steps: [
      { k: "1", title: "Every VM is a Mac app.", body: "It sits in your Dock and opens in its own window." },
      { k: "2", title: "Each one runs on its own.", body: "Its own process, so a crash takes down one VM, not VMPane." },
      { k: "3", title: "An agent asks to run a command.", body: "claude-code wants `sudo apt upgrade -y` as administrator." },
      { k: "4", title: "Nothing runs until you say so.", body: "Deny is the default, and the answer goes in the activity log." },
    ],
  },
  guests: {
    title: ["Three guests.", "Each on the right engine."],
    label: "Guest systems",
    tabs: [
      {
        id: "mac",
        tab: "macOS",
        icon: "laptopcomputer",
        title: "macOS, from Apple's own restore image.",
        facts: [
          { text: "Apple's Virtualization framework" },
          { text: "Live snapshots that keep memory" },
          { text: "Clipboard, files and commands with the guest tools" },
          { text: "Apple allows two macOS VMs running at once per Mac", dim: true },
        ],
      },
      {
        id: "lin",
        tab: "Linux",
        icon: "terminal",
        title: "Linux, checked before it boots.",
        facts: [
          { text: "Ubuntu Server, Debian and Fedora Server from the catalog" },
          { text: "Downloads checked against a pinned SHA-256" },
          { text: "Shared folders over virtiofs" },
          { text: "Any arm64 ISO of your own" },
        ],
      },
      {
        id: "win",
        tab: "Windows",
        icon: "pc",
        title: "Windows 11 on Arm, set up for you.",
        facts: [
          { text: "QEMU with Hypervisor.framework" },
          { text: "Software TPM 2.0 and Secure Boot" },
          { text: "Unattended install from your ISO" },
          { text: "2D display: no DirectX or GPU acceleration", dim: true },
        ],
      },
    ],
  },
  windows: {
    title: ["Set up Windows.", "Without touching it."],
    lead: ["Pick the edition, an account name and a password. VMPane does the rest ", "in about 10 minutes, with no clicks.", " No Microsoft account needed."],
    steps: [
      { k: "Install", title: "Setup runs offline", body: "From your ISO, with no network, so Windows makes the local account you chose." },
      { k: "Eject", title: "The ISO comes out", body: "At the first restart, so Setup can never start over and wipe the disk." },
      { k: "Sign in", title: "Guest tools go in", body: "Windows signs in once, removes the stored password and installs VMPane's drivers." },
      { k: "Finish", title: "Network and display", body: "Added, then Windows starts again. A quit or a Mac restart never loses your place.", min: "about 10 min · 7 on an M4 Pro" },
    ],
  },
  agents: {
    eyebrow: "AI agents",
    title: ["Agents do the work.", "You hold the keys."],
    lead: ["Claude Code, Codex and Gemini connect through `vmpane mcp`. Every VM starts at ", "Off", ", and you choose how far each one opens."],
    levelsLabel: "Pick an access level",
    // AgentPolicySection: the levels' titles and explanations, in order.
    levels: [
      { chip: "Off", title: "Off", explain: "Agents cannot see this VM.", c: "gray" },
      { chip: "Look only", title: "Look only", explain: "Agents can see its state and screenshots.", c: "teal" },
      { chip: "Screen and keyboard", title: "Use the screen and keyboard", explain: "Agents can also click, type, start, pause and snapshot it.", c: "blue" },
      { chip: "Run commands", title: "Run commands", explain: "Agents can also run commands as the logged-in user and copy files in and out.", c: "orange" },
      { chip: "Full control", title: "Full control", explain: "Agents can also run commands as administrator, shut it down and delete snapshots.", c: "red" },
    ],
    defaultLevel: 3,
    hand: "Try a level, watch the log",
  },
  safety: {
    title: ["Off by default.", "Stoppable any time."],
    stop: {
      title: "One switch stops every agent.",
      body: ["From the menu bar, with ", "", ", or `vmpane mcp kill` without the app. Their commands are killed and their port forwards go down."],
      keys: ["⌃", "⌥", "⌘", "."],
    },
    undo: { title: "Undo the whole session.", body: "VMPane snapshots the VM before an agent's first change." },
    ask: { title: "It asks first.", body: "A command waits for you. Deny is the default, and no answer in a minute is a no.", buttons: ["Allow Once", "Deny"] },
    off: { title: "Every VM starts at Off.", body: "Agents cannot even see a VM until you open it to them. Files move only through `~/VMPane Exchange`.", popup: ["Agent access", "Off"] },
    record: { title: "Every call on record.", json: ['{"method":"vm_exec",', ' "level":"exec",', ' "result":', '"denied"', "}"] },
  },
  features: {
    title: ["Snapshots, ports, folders.", "And a command line."],
    label: "Features",
    prev: "Previous feature",
    next: "Next feature",
  },
  limits: {
    eyebrow: "Good to know",
    title: ["What VMPane", "does not do."],
    items: [
      { icon: "cpu", title: "Arm guests only", body: "No x86 or x86-64 systems. There is no emulation." },
      { icon: "pc", title: "2D graphics for Windows", body: "No DirectX or GPU acceleration, and no Hyper-V or WSL2 inside it." },
      { icon: "minus-circle", title: "No USB passthrough", body: "Not in 1.0." },
      { icon: "info", title: "Pre-alpha", body: "Public betas come first. Expect rough edges until 1.0." },
    ],
  },
  faq: {
    title: ["Common questions.", "Short answers."],
  },
  end: {
    title: ["Give your Mac", "a few more computers."],
    body: "A notarized DMG on GitHub Releases, with checksums and the source of the bundled QEMU.",
    docs: "Read the docs",
  },
} as const;
