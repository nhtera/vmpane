# A QEMU VM on a nearly full volume: the helper pauses the guest (with the reason) before writes could fail
# inside it, refuses to resume while the volume stays full, and resumes once space is freed. Uses a 4 GiB
# APFS disk image as the volume and a firmware-only Windows VM (no guest writes needed: the host fills it).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=disk-full

scenario_run() {
    local work volume bundle pid socket result device
    work=$(cd "$(mktemp -d /tmp/vp-df.XXXXXX)" && pwd -P)
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 30; [[ -n ${device:-} ]] && hdiutil detach -force "$device" >/dev/null; rm -rf "$work"; true' RETURN
    hdiutil create -quiet -size 4g -type SPARSE -fs APFS -volname vp-df "$work/vol" || it_fail "hdiutil create failed" || return 1
    device=$(hdiutil attach -nobrowse -mountpoint "$work/mnt" "$work/vol.sparseimage" | awk 'NR == 1 {print $1}')
    volume=$work/mnt
    [[ -d $volume ]] || it_fail "volume not mounted" || return 1

    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle=$volume/W.vmpane
    it_create_bundle "$bundle" windows '.backend = "qemu" | .vz = null | .audio.output = false | .memory.mib = 1024
        | .disks[0].bus = "nvme" | .qemu = {tpm: true, secureBoot: true, gpu: "ramfb", storageBus: "nvme", smbiosUUID: "'"$(uuidgen)"'"}'
    truncate -s 1g "$bundle/current/disk.img"
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1

    # Fill the volume to below the 2 GiB line (256 MiB files of zeros): the guest is paused within seconds.
    local n=0
    while (( $(df -m "$volume" | awk 'NR == 2 {print $4}') > 1500 )); do
        dd if=/dev/zero of="$volume/fill.$((n++))" bs=1m count=256 2>/dev/null || break
    done
    it_wait_for 10 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == paused ]]" \
        || it_fail "the VM was not paused with $(df -m "$volume" | awk 'NR == 2 {print $4}') MiB free" || return 1
    echo "disk-full: paused with $(df -m "$volume" | awk 'NR == 2 {print $4}') MiB free"

    # Resume while still full: refused with insufficientSpace, still paused.
    if result=$(it_rpc "$socket" vm.resume 2>&1); then it_fail "resumed on a full volume: $result"; return 1; fi
    [[ $result == *"GiB"* ]] || it_fail "unexpected refusal: $result" || return 1
    [[ $(it_state "$bundle") == paused ]] || it_fail "not paused after the refused resume" || return 1

    # Free space, then resume.
    rm -f "$volume"/fill*
    it_rpc "$socket" vm.resume >/dev/null || it_fail "resume after freeing space failed" || return 1
    [[ $(it_state "$bundle") == running ]] || it_fail "not running after resume" || return 1
    echo "disk-full: resumed with $(df -m "$volume" | awk 'NR == 2 {print $4}') MiB free"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_wait_for 20 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
