# A Parallels VM imported through the app and booted (Phase 09): the .pvm is opened with VMPane (as from
# Finder's Open With), the import sheet converts it (UITests/ImportUITests.swift drives the app), then the
# imported VM boots headless through the helper.
#
# The .pvm is $VMPANE_ITEST_PVM when set: a real one made by Parallels Desktop (a Linux guest; not committed,
# Parallels licence; see itest/fixtures/README.md); the release tier sets it. Otherwise one is made here from the
# golden Linux disk (qemu-img's Parallels format and the config.pvs / DiskDescriptor.xml layout Parallels
# writes), and the boot is checked by the golden's ready marker on the serial console. Needs an unlocked GUI
# session, as ui-smoke.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=import-parallels

# Writes a Linux .pvm at $1 whose boot disk holds the raw image $2.
it_make_pvm() {
    local pvm=$1 raw=$2 guid="{5fbaabe3-6958-40ff-92a7-860e329aab41}" image sectors
    image="harddisk.hdd.0.$guid.hds"
    mkdir -p "$pvm/harddisk.hdd"
    "$APP/Contents/Helpers/qemu/bin/qemu-img" convert -f raw -O parallels "$raw" "$pvm/harddisk.hdd/$image" || return 1
    sectors=$(($(stat -f %z "$raw") / 512))
    cat >"$pvm/harddisk.hdd/DiskDescriptor.xml" <<XML
<?xml version='1.0' encoding='UTF-8'?>
<Parallels_disk_image Version="1.0">
 <Disk_Parameters><Disk_size>$sectors</Disk_size><Cylinders>1</Cylinders><Heads>16</Heads><Sectors>32</Sectors>
  <Padding>0</Padding></Disk_Parameters>
 <StorageData><Storage><Start>0</Start><End>$sectors</End><Blocksize>2048</Blocksize>
  <Image><GUID>$guid</GUID><Type>Compressed</Type><File>$image</File></Image></Storage></StorageData>
 <Snapshots><Shot><GUID>$guid</GUID><ParentGUID>{00000000-0000-0000-0000-000000000000}</ParentGUID></Shot></Snapshots>
</Parallels_disk_image>
XML
    cat >"$pvm/config.pvs" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<ParallelsVirtualMachine schemaVersion="1.0" dyn_lists="VirtualAppliance 0">
 <Identification><VmUuid>{$(uuidgen)}</VmUuid><VmName>Ubuntu</VmName></Identification>
 <Settings><General><OsType>9</OsType><OsNumber>2309</OsNumber></General></Settings>
 <Hardware>
  <Cpu><Number>2</Number></Cpu>
  <Memory><RAM>2048</RAM></Memory>
  <Hdd dyn_lists="Partition 0" id="0"><Index>0</Index><Enabled>1</Enabled><EmulatedType>1</EmulatedType>
   <SystemName>harddisk.hdd</SystemName><UserFriendlyName>harddisk.hdd</UserFriendlyName></Hdd>
 </Hardware>
</ParallelsVirtualMachine>
XML
}

scenario_run() {
    if ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "import-parallels: skipped: this Mac is locked (the import runs through the app's UI)" >&2
        return 77
    fi
    local work pvm golden="" bundle pid socket log shot lit
    work=$(mktemp -d /tmp/vp-pvm.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    if [[ -n ${VMPANE_ITEST_PVM:-} ]]; then
        pvm=$VMPANE_ITEST_PVM
        [[ -d $pvm ]] || it_fail "VMPANE_ITEST_PVM is not a .pvm: $pvm" || return 1
    else
        golden=$(it_golden_linux) || return 1
        pvm="$work/Ubuntu.pvm"
        it_make_pvm "$pvm" "$golden/current/disk.img" || it_fail "could not make the .pvm" || return 1
    fi
    local before
    before=$(find "$pvm" -type f -exec shasum -a 256 {} + | sort | shasum -a 256)

    log="$work/xcodebuild.log"
    if ! TEST_RUNNER_VMPANE_ITEST_PVM=$pvm TEST_RUNNER_VMPANE_ITEST_SUPPORT=$VMPANE_SUPPORT_DIR \
        it_ui_tests VMPaneUITests/ImportUITests "$log"; then
        grep -E "error:|failed|Test Case .* failed" "$log" | tail -20 >&2
        it_fail "the import through the app failed"
        return 1
    fi
    grep -q "Test Case.*testAParallelsVMOpenedWithVMPaneIsImported.*passed" "$log" \
        || it_fail "the import test did not run (skipped?)" || return 1
    [[ $(find "$pvm" -type f -exec shasum -a 256 {} + | sort | shasum -a 256) == "$before" ]] \
        || it_fail "the import changed the .pvm" || return 1

    bundle=$(find "$VMPANE_SUPPORT_DIR/VMs" -maxdepth 1 -name '*.vmpane' | head -1)
    [[ -n $bundle ]] || it_fail "no VM in the library after the import" || return 1
    [[ $(jq -r .os "$bundle/config.json") == linux ]] || it_fail "the imported VM is not a Linux VM" || return 1
    echo "import-parallels: imported as \"$(jq -r .name "$bundle/config.json")\" ($(du -sh "$bundle" | cut -f1) on disk)"

    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "the imported VM did not start" || return 1
    if [[ -n $golden ]]; then
        # New firmware variables: the guest boots through its disk's removable-media loader, cloud-init finds no seed.
        it_wait_for 180 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log" \
            || it_fail "the imported VM did not boot (no ready marker in 180 s)" || return 1
        echo "import-parallels: the imported VM booted (ready marker)"
    else
        sleep 90
        shot="$work/shot.png"
        it_screenshot "$socket" "$shot" || it_fail "no screenshot of the imported VM" || return 1
        lit=$(it_png_lit_percent "$shot")
        [[ $(it_state "$bundle") == running && $lit -ge 5 ]] \
            || it_fail "the imported VM is not up after 90 s (state $(it_state "$bundle"), screen ${lit}% lit)" || return 1
        echo "import-parallels: the imported VM runs, screen ${lit}% lit"
    fi
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
    return 0
}
