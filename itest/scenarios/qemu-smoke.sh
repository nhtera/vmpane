# The shipped QEMU bundle works end to end under HVF: qemu-system-aarch64 boots the shipped EDK2 (Secure
# Boot variable template) to the UEFI shell with swtpm attached; QMP reports the VM running and lists the
# TPM. Uses the app's copy (Contents/Helpers/qemu, Contents/Resources/qemu/share) when the app has one,
# else build/qemu-bundle (qemu/scripts/package.sh).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=qemu-smoke

qmp() { /usr/bin/python3 -I "$VMPANE_ROOT/itest/lib/qmp.py" "$@"; }

scenario_run() {
    local root share work swtpm_pid qemu_pid status tpm
    if [[ -x $APP/Contents/Helpers/qemu/bin/qemu-system-aarch64 ]]; then
        root=$APP/Contents/Helpers/qemu share=$APP/Contents/Resources/qemu/share
    else
        root=$VMPANE_ROOT/build/qemu-bundle share=$VMPANE_ROOT/build/qemu-bundle/share
    fi
    [[ -x $root/bin/qemu-system-aarch64 && -f $share/edk2-aarch64-code.fd ]] ||
        { echo "qemu-smoke: no QEMU bundle with firmware (qemu/scripts/package.sh)"; return 77; }
    echo "qemu-smoke: $root"
    # Short path: Unix socket paths are limited to 104 bytes.
    work=$(mktemp -d /tmp/vp-qs.XXXXXX)
    trap 'set +e; kill -9 $qemu_pid $swtpm_pid 2>/dev/null; rm -rf "$work"; true' RETURN

    # pflash devices are exactly 64 MiB; the bundle ships the files unpadded.
    cp "$share/edk2-aarch64-code.fd" "$work/code.fd"
    cp "$share/edk2-aarch64-vars-sb.fd" "$work/vars.fd"
    truncate -s 64m "$work/code.fd" "$work/vars.fd"

    mkdir "$work/tpm"
    "$root/bin/swtpm" socket --tpm2 --tpmstate dir="$work/tpm" --ctrl type=unixio,path="$work/tpm.sock" \
        --log file="$work/swtpm.log" &
    swtpm_pid=$!
    it_wait_for 10 test -S "$work/tpm.sock" || it_fail "swtpm did not open its socket" || return 1

    "$root/bin/qemu-system-aarch64" -L "$share/qemu" -machine virt -accel hvf -cpu host -m 1024 -nodefaults \
        -display none -serial file:"$work/serial.log" -qmp unix:"$work/qmp.sock",server=on,wait=off \
        -drive if=pflash,format=raw,readonly=on,file="$work/code.fd" -drive if=pflash,format=raw,file="$work/vars.fd" \
        -chardev socket,id=chrtpm,path="$work/tpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis-device,tpmdev=tpm0,ppi=off -device ramfb 2>"$work/qemu.err" &
    qemu_pid=$!
    it_wait_for 60 grep -aqs "UEFI Interactive Shell" "$work/serial.log" ||
        { cat "$work/qemu.err"; it_fail "EDK2 did not reach the UEFI shell"; return 1; }

    status=$(qmp "$work/qmp.sock" query-status | jq -r .status)
    [[ $status == running ]] || it_fail "query-status: $status" || return 1
    tpm=$(qmp "$work/qmp.sock" query-tpm | jq -r '[.[].id] | join(",")')
    [[ $tpm == tpm0 ]] || it_fail "query-tpm: '$tpm'" || return 1
    echo "qemu-smoke: UEFI shell under HVF, status=$status, tpm=$tpm"
    qmp "$work/qmp.sock" quit >/dev/null || true
    it_wait_exit "$qemu_pid" 10 || it_fail "QEMU did not quit" || return 1
    return 0
}
