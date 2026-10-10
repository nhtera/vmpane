# VM bundle format

A VM is a `.vmpane` package (UTI `app.vmpane.vm`, conforms to `com.apple.package`). Directories are 0700
and files 0600. Every JSON file carries `schemaVersion` and is written in VMPane's canonical form
(sorted keys, pretty-printed), crash-safely (temp file, `F_FULLFSYNC`, rename, directory sync).

```
Name.vmpane/
  config.json            settings (schema below)
  bundle.lock            flock'd by the helper (and inherited by disk-writing children) while the VM runs
  icon.png  thumbnail.png
  current/               the live file set, swapped as one unit by a snapshot restore
    generation.json      {schemaVersion, generationId, parentSnapshotId}
    disk.img             raw sparse disk (the only disk format)
    aux/                 efi_vars.fd (UEFI variables) | AuxiliaryStorage, HardwareModel, MachineIdentifier
                         | tpm/ (swtpm state, Windows)
    state/               saved RAM state (suspend.vzvmsave | state.qemu + state-qemu.json) + suspend.json
                         {generationId, deviceSetHash, hostBuild, backendVersion}
  snapshots/<uuid>/      meta.json, disk.img, aux/, state/ — meta.json is written last
  install/               Windows install state; never snapshotted or cloned
  restore.journal        present only while a restore is in progress
  logs/                  helper.log serial.log qemu.log swtpm.log mcp-audit.jsonl
```

## config.json (schema 1)

Typed fields are listed in `Packages/VMPaneKit/Sources/VMPaneCore/Config/VMConfigV1.swift`; an example is
`Packages/VMPaneKit/Tests/VMPaneCoreTests/Fixtures/config-v1.json`. Unknown keys, at any level, are kept
when VMPane rewrites the file, so a newer VMPane's additions survive an older one's edits.

- A file with a newer `schemaVersion` than this build supports is opened read-only and never written.
- An older one is migrated step by step (`ConfigMigrator`), only by the holder of `bundle.lock`, after
  a backup `config.v<N>.<timestamp>.bak.json`. Without the lock (a helper is running) a reader migrates
  in memory only.
- Until the first public beta the schema stays at version 1 and may change with fixture updates; from
  then on every change needs a migration.

## Identity

`id` (VM UUID), each NIC's `macAddress`, `platform.machineIdentifier` (VZ) and `qemu.smbiosUUID` make a
VM a distinct machine. A clone gets new values (the machine identifier is regenerated on first start).
A bundle found to share an id or a MAC with another library VM — typically a Finder copy — gets a new
identity when it is opened or imported (never the VM already in the library); its saved RAM state is
dropped. New VMs and clones are built under a hidden staging name and published by an exclusive rename;
deletes rename to a hidden name first. Bundles whose parts are symlinks, or whose disk paths leave the
bundle, are refused.

## Generations and saved state

Every operation that replaces the live set (restore, disk replacement) gives `current/` a new
`generationId`. Saved RAM state is used only if its `generationId` and `deviceSetHash` (SHA-256 of the
guest-visible hardware) match the live set; otherwise the VM cold boots and the state is deleted.
Settings that do not change hardware (name, UI, MCP policy, clipboard, port forwards) do not invalidate
state. Exception: a restore that fails because the Mac is locked keeps the state (`macLocked`); VZ can
decrypt saved memory only while the Mac is unlocked.

## Installing

`install` is present only until the guest is installed:

- `install.restoreImage` (macOS): the `.ipsw` to install from on first start. Removed after the install,
  when `platform.machineIdentifier` is recorded.
- `install.media` (Linux): the id of the `removable` entry holding the installer ISO (read-only USB mass
  storage). Removed, with that entry, at the first stop after the install finished: the system disk has a
  partition table and `current/aux/efi_vars.fd` has an OS boot entry (`\EFI\<os>\…`, written when the
  installer sets up the boot loader). Not while saved RAM state waits (the device change would discard
  it). VZ reboots Linux guests in place, so the installed system first runs with the ISO still attached;
  its boot entry comes first, so the ISO goes unused.

## Snapshots and restore

- Create: clone the live files into `snapshots/<id>.partial/`, sync, write `meta.json`, rename to
  `snapshots/<id>/`, sync. A snapshot exists exactly when its `meta.json` does.
- Restore (VM stopped): build `.restore-<generation>/` from clones, write `restore.journal`, swap it with
  `current/` in one `renameatx_np(RENAME_SWAP)`, then delete the old set and the journal.
- Whoever takes `bundle.lock` next finishes an interrupted restore and removes leftovers (`*.partial`,
  `*.deleting`, `.restore-*`, temp files). A crash at any step leaves the old or the new set, never a mix.
  The journal's paths are never used: a bundle from elsewhere cannot point the cleanup outside itself.
- Snapshots need APFS (`clonefile`); on other volumes they are unavailable and clones become full copies.
- Live (RAM-state) snapshots and suspends need free space of at least RAM × 1.1 + 5 GiB.

## Run directory

`~/Library/Application Support/VMPane/run/` (0700), per VM (`sid` = first 8 hex digits of the id):
`<sid>.sock` (control socket, 0600), `<sid>.pid` (helper record: pid, start time, path, runtime version,
bundle path), `<sid>.children` (one line per child: the child and the helper that started it), `<sid>/`
(child sockets). A process is identified by pid + start time (its path too, while the kernel can still
report it). Children are recorded before they run (spawned suspended), and only the dead helper's own
children are ever reaped. Run files are only touched when their pid record names the bundle, and
unreadable ones are left alone. `library.json` next to it
indexes the VMs (id, path, bookmark); `runtime/<version>/` holds the helper copies running VMs use.
