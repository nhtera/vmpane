# macOS guests

macOS runs in VMPane on Apple's Virtualization framework, installed from an Apple restore image (IPSW). Apple
allows two macOS VMs running at once per Mac.

## Creating a macOS VM

In **New VM**, choose **macOS**, then the restore image:

- **From the catalog**: VMPane's list of restore images (today macOS Sequoia 15.6.1), downloaded from Apple and
  checked against a pinned SHA-256. An interrupted download resumes; a download that does not match is deleted.
  The row says **Downloaded** once the image (about 17 GB) is in VMPane's cache, and it is checked again each time
  a VM is created from it.
- **Your own**: **Choose a restore image (.ipsw)…**. VMPane does not check a file you choose; your Mac must
  support the image's hardware model, or the install stops.

Then the resources (4 processors, 8 GB of memory and an 80 GB disk unless you change them; your Mac keeps at
least 4 GB of memory, and the disk only takes the space the system actually uses), the name, shared folders,
the clipboard, sound and microphone, and whether AI agents may use the VM (**Off** unless you choose otherwise).
**Create** starts the VM.

## Installing

The first start installs macOS: VMPane needs about 25 GB free on the VM's disk volume, then Apple's installer runs in
the VM's window under **Installing macOS**. You can leave it running; VMPane restarts the VM when it is done. If
the install stops part way (a quit, a Mac restart), the next start installs again from the beginning.

The installed system starts at Setup Assistant: set it up as you would a new Mac.

## Two at a time

Apple's licence and the Virtualization framework allow two macOS VMs running at once on a Mac. VMPane counts a
macOS VM while its VM app is open, even after the VM shut down. Opening a third (from the app, `vmpane` or an AI
agent) fails with *macOS allows 2 macOS virtual machines running at once on a Mac. Shut one down to start this
one.*

## Guest tools

The guest tools add the clipboard (text and images both ways; files copied in the VM arrive on your Mac in
`~/Downloads/VMPane/<VM>`), dragging files into the VM (they land in **Desktop › VMPane Drops**, with someone
logged in), and, for AI agents, running commands and copying files. VMPane shares them read-only with every macOS VM. In the VM, open
`/Volumes/My Shared Files/vmpane-tools` in the Finder and double-click **VMPane Agent.pkg** (it needs macOS 15
or later in the VM). It installs the agent in `/Library/Application Support/VMPane/Agent`, with a launch daemon
(`app.vmpane.agent`, logging to `/Library/Logs/VMPane/agent.log`) and a launch agent for each login.

The display follows the window size without the guest tools.

## Shared folders

macOS mounts shared folders itself: each appears in `/Volumes/My Shared Files/<name>` (a second folder with the
same name gets "Name 2"). If a change to the shared folders does not show in a running VM, restart it.

## Snapshots

- A snapshot of a running VM (**Take Live Snapshot** in the Snapshots sheet, or **Take Snapshot** in the VM's
  window) saves its memory too: restoring it brings back the running system. It is marked *Contains RAM*:
  anything in memory, passwords and keys too, is in it.
- A snapshot of a stopped VM (**Take Snapshot**) saves its disks.
- A live snapshot's memory is encrypted with a key of your Mac: restoring one needs the Mac unlocked.
- Settings › General › **Keep live snapshots' memory out of Time Machine** is on by default.

VMPane never takes a disk-only snapshot of a running macOS VM: the macOS agent cannot freeze its file systems.
If the snapshot before an agent's first change cannot be a live one, that change is refused until you stop the
VM, take a snapshot yourself, or turn off **Snapshot before each agent session**.

## Display

The VM's display follows its window by default (Settings › **Follow the window size**); otherwise pick a
**Resolution**. Both change while the VM runs. Input is a Mac keyboard and trackpad.

## Limits

- Rosetta is for Linux guests only.
- Changes to memory, processors, sound and the clipboard take effect at the next start.
