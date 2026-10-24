// SPDX-License-Identifier: Apache-2.0

// The landing page's copy, English only (design draft v5). Every claim maps to
// shipped behaviour and uses the app's own strings: the access levels and
// their explanations are AgentPolicySection's, the dialog is the agent
// approval prompt's, the menu items are the menu bar menu's. `code` in
// backticks renders as <code>.

export type Tint = "blue" | "orange" | "green" | "purple" | "red";

export const landing = {
  hero: {
    title: ["Three systems.", "One Mac."],
    sub: "Run macOS, Linux and Windows 11 in native Mac windows. Lend one to an AI agent, within limits you set.",
    docs: "Read the docs",
    meta: "Free and open source. Requires macOS 15 or later and a Mac with Apple silicon.",
  },
  story: {
    label: "How VMPane feels: a VM on your Mac and an agent asking first",
    menubar: ["VMPane", "File", "Edit", "View", "Window", "Help"],
    clock: "Mon Oct 12 9:41 PM",
    typed: { agent: "claude-code", verb: "wants to run", command: "sudo apt upgrade -y" },
    steps: [
      { title: "Every VM is a Mac app.", body: "It sits in your Dock and opens in its own window." },
      { title: "Each one runs on its own.", body: "Its own process, so a crash takes down one VM, not VMPane." },
      { title: "An agent asks to run a command.", body: "claude-code wants `sudo apt upgrade -y` as administrator." },
      { title: "Nothing runs until you say so.", body: "Deny is the default, and the answer goes in the activity log." },
    ],
  },
  // The statement under the Mac: its words light up one by one as it scrolls into view. It says what the story
  // above has not (each claim is on the page, in the safety cards).
  statement: {
    label: "VMPane in one sentence",
    text: "Agents see only the VMs you open to them, ask before they run a command, and a whole agent session can be undone.",
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
        title: "Linux, ready in minutes.",
        facts: [
          { text: "Ubuntu, Debian and Fedora from their own cloud images: nothing to click through" },
          { text: "Or an installer ISO, the catalog's or yours, checked before it boots" },
          { text: "Made in the background: the library shows each stage" },
          { text: "Shared folders over virtiofs" },
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
      { title: "Setup runs offline", body: "From your ISO, with no network, so Windows makes the local account you chose." },
      { title: "The ISO comes out", body: "At the first restart, so Setup can never start over and wipe the disk." },
      { title: "Guest tools go in", body: "Windows signs in once, removes the stored password and installs VMPane's drivers." },
      { title: "Network and display", body: "Added, then Windows starts again. A quit or a Mac restart never loses your place.", min: "About 10 minutes in all, 7 on an M4 Pro." },
    ],
  },
  agents: {
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
    // A real session (itest/scenarios/mcp-demo.sh; src/content/demo-transcript.txt is its unedited transcript).
    transcript: {
      summary: "Read the whole session, unedited",
      note: "Claude Code was asked in plain words to start macOS, Ubuntu and Windows 11 in turn, snapshot Windows, run a small test in each, read the screen and stop it. Unedited, its recoveries included; answers are cut at 400 characters.",
    },
    // The clients that connect through `vmpane mcp` (docs/mcp.md), circling the app in the section's picture.
    orbit: {
      label: "Claude Code, Codex and Gemini connect to VMPane through vmpane mcp.",
      command: "vmpane mcp",
      clients: ["Claude Code", "Codex", "Gemini"],
    },
  },
  // One real session, step by step, pinned beside its own transcript (src/content/demo-transcript.txt, from
  // itest/scenarios/mcp-demo.sh). The lines are the transcript's, in order; long answers end in "…" where they
  // are cut. Kinds: ask (the request, as the transcript's note words it), call (→), reply (←), said (Claude:).
  session: {
    title: ["One real session.", "Claude Code tests three VMs."],
    label: "A real agent session, step by step",
    window: "claude — vmpane mcp",
    library: "VMPane",
    pass: "PASS",
    snapshot: "before tests",
    // The library beside the transcript: each VM's state at each step.
    vms: ["macOS", "Ubuntu", "Windows 11"],
    snapshotLabel: "Snapshot",
    steps: [
      {
        title: "You ask. It starts each VM.",
        body: "In plain words, in Claude Code: `vmpane mcp` hands it the tools. `vm_power` starts a VM and returns once its guest tools answer.",
        state: ["Running", "Stopped", "Stopped"],
        lines: [
          ["ask", "Start macOS, Ubuntu and Windows 11 in turn, snapshot Windows, run a small test in each, read the screen and stop it."],
          ["call", "vm_list {}"],
          ["reply", '{"vms":[{"id":"7039e2fd","name":"Ubuntu","os":"linux","state":"stopped"},…'],
          ["call", 'vm_power {"vm": "macOS", "action": "start", "wait_for": "guest_tools", "timeout_s": 300}'],
          ["reply", '{"guest":{"os":"macos","osVersion":"15.6.1","toolsVersion":"1.0.0-beta.10"},"state":"running"}'],
        ],
      },
      {
        title: "It acts, and recovers.",
        body: "Every answer says what happened. The first command came too early; the agent saw why, waited, and ran it again.",
        state: ["Running", "Stopped", "Stopped"],
        pass: [true, false, false],
        lines: [
          ["call", 'vm_exec {"vm": "macOS", "argv": ["/bin/zsh", "-c", "if (( 6 * 7 == 42 )); then echo PASS; else echo FAIL; fi"]}'],
          ["reply", "no user session helper is connected"],
          ["said", "macOS is up; the first exec failed because the user session helper wasn't connected yet — status now shows a session, retrying."],
          ["call", 'vm_exec {"vm": "macOS", "argv": ["/bin/zsh", "-c", "if (( 6 * 7 == 42 )); then echo PASS; else echo FAIL; fi"]}'],
          ["reply", '{"exitCode":0,"stderr":"","stdout":"PASS\\n","timedOut":false,"truncated":false}'],
        ],
      },
      {
        title: "It reads the screen.",
        body: "`vm_read_screen` gives the text everywhere, and the controls on Windows and macOS, to click by id.",
        state: ["Stopped", "Running", "Stopped"],
        pass: [true, false, false],
        lines: [
          ["call", 'vm_read_screen {"vm": "Ubuntu", "max_items": 60}'],
          ["reply", '{"screen":{"h":983,"scale":1.3673469387755102,"w":1568},"source":"ocr","truncated":true,"untrusted_guest_text":{"ocr":[{"id":"t1","rect":[39,1,412,12],"text":"] Started fstrim.timer - Discard unused filesystem blocks o…'],
          ["said", "Ubuntu is still booting (systemd log on screen, no user session yet). Waiting a bit longer."],
        ],
      },
      {
        title: "It snapshots, then reports.",
        body: "One call saves Windows before its test. At the end: three passes, three VMs stopped again, and what did not go as planned in the report.",
        state: ["Stopped", "Stopped", "Stopped"],
        pass: [true, true, true],
        snap: true,
        lines: [
          ["call", 'vm_power {"vm": "Windows 11", "action": "start", "wait_for": "guest_tools", "timeout_s": 400}'],
          ["reply", '{"guest":{"os":"windows","osVersion":"10.0.26300.9457","toolsVersion":"1.0.0-beta.1"},"state":"running"}'],
          ["call", 'vm_snapshot_create {"vm": "Windows 11", "name": "before tests"}'],
          ["reply", '{"backendVersion":"1.0.0-beta.10","crashConsistent":false,"createdAt":"2026-10-22T12:27:23Z",…'],
          ["said", "All three VMs ran in order, all three tests printed PASS, and all three VMs are stopped again."],
          ["done", "[done: 44 turns, 390 s]"],
        ],
      },
    ],
  },
  safety: {
    title: ["Off by default.", "Stoppable any time."],
    stop: {
      title: "One switch stops every agent.",
      body: ["From the menu bar, with ", "", ", or `vmpane mcp kill` without the app. Their commands are killed and their port forwards go down."],
      keys: ["⌃", "⌥", "⌘", "."],
      clock: "Mon 9:41 PM",
    },
    undo: { title: "Undo the whole session.", body: "VMPane snapshots the VM before an agent's first change." },
    ask: { title: "It asks first.", body: "A command waits for you. Deny is the default, and no answer in a minute is a no.", buttons: ["Allow Once", "Deny"] },
    off: { title: "Every VM starts at Off.", body: "Agents cannot even see a VM until you open it to them. Files move only through `~/VMPane Exchange`.", popup: ["Agent access", "Off"] },
    record: { title: "Every call on record.", body: "Each action of a batch too, with typed text kept as a hash.", json: ['{"method":"vm_exec",', ' "level":"exec",', ' "result":', '"denied"', "}"] },
    takeOver: {
      title: "Take over any time.",
      body: "While an agent works, its window says who and what. Type or click in it, and the agent waits.",
      pill: ["claude-code · Run commands", "Take Over", "Stop"],
    },
    signIn: {
      title: "Sign-in without showing the password.",
      body: "VMPane types it at the lock screen itself; agents never see it. If they can run commands, it asks you first.",
      // the lock screen's password field as VMPane fills it: one dot per typed character
      field: { dots: 12, by: "Typed by VMPane" },
    },
  },
  features: {
    title: ["Snapshots, ports, folders.", "And a command line."],
    label: "Features",
    prev: "Previous feature",
    next: "Next feature",
    pause: "Pause the features",
    play: "Play the features",
    show: "Show",
    slides: [
      { scene: "snapshots", wall: "e", title: "Snapshots", body: "Live with memory for a running VM, disks for a stopped one." },
      { scene: "ports", wall: "a", title: "Port forwarding", body: "From this Mac only, unless you let other computers on the network connect." },
      { scene: "sharing", wall: "c", title: "Shared folders", body: "Your Mac's folders inside the VM, one directory per share." },
      { scene: "import", wall: "d", title: "Import from Parallels", body: "Turn a Parallels Linux or Windows VM into a VMPane VM, converted in a sandbox." },
      { scene: null, wall: "b", title: "The vmpane command", body: "Start, snapshot, exec, copy and forward ports from your terminal." },
      { scene: "clipboard", wall: "e", title: "Clipboard and drag", body: "Moves only while the VM's window is in front, or when you drop on it." },
    ],
    terminalTitle: "Terminal",
    // The terminal slide: real `vmpane` commands and their output (CLI/Commands/Library.swift, Port.swift).
    terminal: [
      [{ t: "$ ", d: true }, { t: "vmpane list" }],
      [{ t: "NAME          ID        OS       STATE", d: true }],
      [{ t: "ubuntu-24-04  3f9a1c2e  linux    " }, { t: "running", g: true }],
      [{ t: "win11         a4d07b91  windows  " }, { t: "running", g: true }],
      [{ t: "$ ", d: true }, { t: "vmpane exec ubuntu-24-04 -- uname -m" }],
      [{ t: "aarch64" }],
      [{ t: "$ ", d: true }, { t: "vmpane port add ubuntu-24-04 8080:80" }],
      [{ t: "pf-1" }],
    ],
  },
  // One section: what VMPane does not do, beside what a new VM gets (the requirements below).
  limits: {
    title: ["Good to know.", "Before you install."],
    heading: "What VMPane does not do",
    items: [
      { icon: "cpu", title: "Arm guests only", body: "No x86 or x86-64 systems. There is no emulation." },
      { icon: "pc", title: "2D graphics for Windows", body: "No DirectX or GPU acceleration, and no Hyper-V or WSL2 inside it." },
      { icon: "minus-circle", title: "No USB passthrough", body: "Not in 1.0." },
      { icon: "info", title: "Public beta", body: "Betas come first. Expect rough edges until 1.0." },
    ],
  },
  // What the new-VM sheet gives each system on a Mac with room (WizardModel.Recommended); on a smaller Mac it gives
  // at most half its processors and memory, never less than the minimum.
  requirements: {
    heading: "What a VM gets",
    caption: "What VMPane gives a new VM, and the least memory it needs",
    columns: ["System", "Processors", "Memory", "Disk", "Memory at least"],
    rows: [
      ["macOS", "4", "8 GB", "80 GB", "4 GB"],
      ["Linux", "4", "4 GB", "64 GB", "2 GB"],
      ["Linux with a desktop", "4", "8 GB", "64 GB", "4 GB"],
      ["Windows 11", "4", "8 GB", "64 GB", "4 GB"],
    ],
    note: "On a smaller Mac, a new VM gets about half its processors and memory, never less than the minimum, and the Mac keeps 4 GB for itself. You can change all of it. Disks take only the space the system uses.",
  },
  faq: {
    title: ["Common questions.", "Short answers."],
  },
  // The HTML windows the page draws (src/components/landing/mocks.tsx), in the app's own words: the library's
  // rows (StateDot labels), the VM window, the agent approval dialog (ConfirmationDialog), Settings › AI agents,
  // the activity list (AgentActivityView: "client (claimed): method", the time, the refusal's reason), the menu
  // bar menu, the Snapshots sheet, port forwarding, shared folders, the Parallels import and the Windows
  // install overlay. Each picture's description (`label`) is what a screen reader announces.
  mock: {
    vm: "Ubuntu 24.04",
    // The app's system tiles (SystemTile): a letter for a Linux distribution, four panes for Windows, a laptop for
    // macOS (never Apple's logo on the web), in each system's colours.
    vms: [
      { name: "Ubuntu 24.04", tile: "U", brand: "ubuntu", os: "Linux", state: "Running", st: "run", spec: "4 CPUs · 4 GB" },
      { name: "Windows 11", tile: "panes", brand: "windows", os: "Windows", state: "Running", st: "run", spec: "4 CPUs · 8 GB" },
      { name: "macOS 26", tile: "mac", brand: "macos", os: "macOS", state: "Suspended", st: "susp", spec: "4 CPUs · 8 GB" },
      { name: "Fedora 42", tile: "F", brand: "fedora", os: "Linux", state: "Stopped", st: "", spec: "2 CPUs · 4 GB" },
    ],
    library: {
      label: "VMPane's library: Ubuntu and Windows running, macOS suspended, Fedora stopped; Ubuntu is chosen, and its agent activity shows a denied command.",
      // The sidebar's filters and their counts (LibraryFilter).
      filters: [["All", "4", "list", "gray"], ["Running", "2", "play", "green"], ["Agent active", "1", "sparkle", "blue"]],
      facts: [["System", "Linux"], ["On disk", "9.8 GB"]],
      thumb: ["ubuntu@ubuntu:~$ uname -m", "aarch64"],
      activity: "Agent activity",
    },
    term: {
      label: "Ubuntu in its own window, listing package updates.",
      prompt: "ubuntu@ubuntu",
      command: "apt list --upgradable",
      out: ["Listing... Done", "curl/noble-updates 8.5.0-2ubuntu10.6 arm64", "openssl/noble-updates 3.0.13-0ubuntu3.5 arm64", "python3.12/noble-updates 3.12.3-1ubuntu0.8 arm64"],
    },
    alert: {
      label: "VMPane asks: claude-code, an AI agent, wants to run sudo apt upgrade -y as administrator in Ubuntu 24.04. Deny is the default.",
      title: "“claude-code 2.1” (an AI agent) wants to run a command as administrator in Ubuntu 24.04",
      info: "Allow it this once? Check what it does first.",
      command: "sudo apt upgrade -y",
    },
    // The demo session: each call, the access level it needs, its time and why it was refused.
    session: [
      { method: "vm.screenshot", need: 1, time: "Oct 12, 2026 at 9:40:12 PM" },
      { method: "vm.input.pointer", need: 2, time: "Oct 12, 2026 at 9:40:31 PM" },
      { method: "agent.exec", need: 3, time: "Oct 12, 2026 at 9:41:02 PM" },
      { method: "agent.exec", need: 4, time: "Oct 12, 2026 at 9:41:20 PM", asked: true },
    ],
    // MCP clients name themselves with their version (MCPServer.noteClient); the helper marks the name as claimed.
    client: "claude-code 2.1 (claimed)",
    levels: ["off", "observe", "control", "exec", "admin"],
    noActivity: "No agent has used this VM.",
    allowed: "Allowed",
    refused: "Refused",
    personSaidNo: "the person at this Mac did not allow it",
    // The settings sheet's sections (SettingsSection) with their icons and colours; AI agents is open.
    settings: {
      title: "Settings",
      section: "AI agents",
      levels: "What agents may do",
      sections: [["General", "sliders", "gray"], ["Hardware", "cpu", "blue"], ["Display", "macwindow", "indigo"], ["Sharing", "folder", "green"], ["AI agents", "sparkle", "purple"], ["Network", "network", "teal"], ["Port Forwarding", "import", "orange"]],
    },
    toggles: [
      { label: "Ask before an agent runs a command", on: true },
      { label: "Snapshot before each agent session", on: true },
      { label: "Record typed text in the activity log", on: false },
      { label: "Let agents read and set the clipboard", on: false },
    ],
    menu: {
      label: "VMPane's menu bar menu: the running VMs, and Stop All AI Agents with its shortcut, Control Option Command period.",
      vms: ["Ubuntu 24.04 — Running", "Windows 11 — Running"],
      stop: ["Stop All AI Agents", "⌃⌥⌘."],
      items: ["Open VMPane"],
      quit: ["Quit VMPane", "⌘Q"],
    },
    snapshots: {
      label: "The Snapshots sheet: two snapshots taken before agent sessions, with their memory, and Undo Agent Session.",
      title: "Snapshots",
      rows: [
        { name: "agent: claude-code 2.1 2026-10-12T14:40:31", date: "Oct 12, 2026 at 9:40 PM", size: "1.2 GB", ram: true, agent: true },
        { name: "agent: claude-code 2.1 2026-10-11T11:12:40", date: "Oct 11, 2026 at 6:12 PM", size: "860 MB", ram: true, agent: true },
        { name: "before-upgrade", date: "Oct 10, 2026 at 11:03 AM", size: "2.4 GB" },
      ],
      ram: "Contains RAM",
      agent: "Before agent",
      take: "Take Live Snapshot",
      buttons: ["Undo Agent Session…", "Delete…", "Done"],
    },
    ports: {
      label: "Port forwarding: Mac ports 8080 and 2222 forwarded to the VM, and a port the VM listens on.",
      title: "Port forwarding",
      rules: ["TCP 127.0.0.1:8080 → guest 80", "TCP 127.0.0.1:2222 → guest 22"],
      listening: "The VM listens on",
      open: ["TCP 5432 (postgres)", "Forward"],
      add: "Add Port Forward…",
    },
    sharing: {
      label: "Shared folders: Projects, read and write, and Reference, read only.",
      title: "Sharing",
      shares: [{ path: "/Users/you/Projects", readOnly: false }, { path: "/Users/you/Reference", readOnly: true }],
      readOnly: "Read only",
      add: "Add Folder…",
    },
    import: {
      label: "Import from Parallels: a Parallels Linux VM about to become a VMPane VM.",
      title: "Import “Ubuntu Server” from Parallels",
      facts: [["System", "Linux"]],
      note: "Afterwards: remove Parallels Tools in the guest and install VMPane's guest tools.",
      buttons: ["Cancel", "Import"],
    },
    clipboard: {
      label: "Sharing settings: the clipboard both ways, sound output on, the microphone off.",
      title: "Settings",
      rows: [["Clipboard", "Both ways"]],
      toggles: [{ label: "Sound output", on: true }, { label: "Microphone", on: false }],
    },
    // A macOS guest's desktop: Finder's menu bar and Terminal, with text copied on the Mac pasted in the VM (the
    // guest tools share the clipboard).
    macos: {
      label: "A macOS 26 VM in its own window: Terminal shows its version and arm64, and pastes text copied on the Mac.",
      name: "macOS 26",
      menubar: ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
      terminal: "Terminal",
      lines: [
        ["% ", "sw_vers -productVersion"],
        ["", "26.0"],
        ["% ", "uname -m"],
        ["", "arm64"],
        ["% ", "pbpaste"],
        ["", "Copied on the Mac, pasted in the VM."],
      ],
    },
    shares: {
      label: "Ubuntu's terminal: the Mac's shared folders mounted over virtiofs, one of them read only.",
      lines: [
        ["$ ", "mount -t virtiofs"],
        ["", "vmpane-shares on /mnt/vmpane type virtiofs (rw,relatime)"],
        ["$ ", "ls /mnt/vmpane"],
        ["", "Projects  Reference"],
        ["$ ", "touch /mnt/vmpane/Reference/todo.txt"],
        ["", "touch: cannot touch '/mnt/vmpane/Reference/todo.txt': Read-only file system"],
      ],
    },
    install: {
      label: "Windows 11 on Arm installing in VMPane with no clicks: drivers and tools going in.",
      name: "Windows 11",
      title: "Installing Windows",
      message: "Windows started; installing drivers and tools",
      percent: 80,
      note: "You can leave this running; VMPane restarts the VM when it is done.",
    },
  },
  end: {
    title: ["Give your Mac", "a few more computers."],
    body: "A notarized DMG on GitHub Releases, with checksums and the source of the bundled QEMU.",
    docs: "Read the docs",
  },
} as const;
