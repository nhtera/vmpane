# QEMU and swtpm under their sandbox profiles (Config/Sandbox/*.sb, applied with sandbox-exec), from a
# runtime copy laid out like runtime/<version>/qemu: swtpm keeps its TPM state in the VM bundle and listens
# in the run directory; QEMU boots the shipped firmware to the UEFI shell with HVF and the TPM; each is
# denied a file outside its bundle and run directory. With VMPANE_SIGN_IDENTITY set to a real identity the
# copy is first signed like a release (hardened runtime, scripts/sign.sh --qemu-only), proving the profiles
# against product-signed binaries.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=qemu-sandbox

qmp() { /usr/bin/python3 -I "$VMPANE_ROOT/itest/lib/qmp.py" "$@"; }

scenario_run() {
    local bin share work runtime bundle run outside swtpm_pid qemu_pid tpm
    if [[ -x $APP/Contents/Helpers/qemu/bin/qemu-system-aarch64 ]]; then
        bin=$APP/Contents/Helpers/qemu share=$APP/Contents/Resources/qemu/share
    else
        bin=$VMPANE_ROOT/build/qemu-bundle share=$VMPANE_ROOT/build/qemu-bundle/share
    fi
    [[ -x $bin/bin/qemu-system-aarch64 && -f $share/edk2-aarch64-code.fd ]] ||
        { echo "qemu-sandbox: no QEMU bundle with firmware (qemu/scripts/package.sh)"; return 77; }
    # Short (Unix socket paths) and resolved: sandbox rules match real paths, and /tmp is a symlink.
    work=$(cd "$(mktemp -d /tmp/vp-sb.XXXXXX)" && pwd -P)
    trap 'set +e; kill $qemu_pid $swtpm_pid 2>/dev/null; rm -rf "$work"; true' RETURN
    runtime=$work/rt/qemu bundle=$work/b run=$work/r outside=$work/outside
    mkdir -p "$runtime" "$bundle/tpm" "$run" "$outside"
    ditto "$bin/bin" "$runtime/bin"
    ditto "$bin/lib" "$runtime/lib"
    ditto "$share" "$runtime/share"
    if [[ ${VMPANE_SIGN_IDENTITY:--} != - ]]; then
        "$VMPANE_ROOT/scripts/sign.sh" --qemu-only "$runtime" >/dev/null || it_fail "signing the runtime copy failed" || return 1
        [[ $(codesign -dv "$runtime/bin/qemu-system-aarch64" 2>&1) == *flags=*runtime* ]] ||
            it_fail "no hardened runtime after signing" || return 1
        echo "qemu-sandbox: runtime copy signed with the hardened runtime"
    fi
    cp "$runtime/share/edk2-aarch64-vars-sb.fd" "$bundle/vars.fd"
    cp "$runtime/share/edk2-aarch64-code.fd" "$bundle/code.fd"
    truncate -s 64m "$bundle/vars.fd" "$bundle/code.fd"
    printf 'x%.0s' {1..4096} >"$outside/disk.img"

    sb() {  # sb <profile> <command…>
        local profile=$1
        shift
        TMPDIR=$run sandbox-exec -f "$VMPANE_ROOT/Config/Sandbox/$profile.sb" \
            -D BUNDLE="$bundle" -D RUNDIR="$run" -D RUNTIME="$runtime" "$@"
    }

    # swtpm may not keep state outside the bundle.
    sb swtpm "$runtime/bin/swtpm" socket --tpm2 --tpmstate dir="$outside" --ctrl type=unixio,path="$run/deny.sock" \
        --flags startup-clear >/dev/null 2>"$run/swtpm-deny.err" &
    swtpm_pid=$!
    sleep 2
    if kill -0 "$swtpm_pid" 2>/dev/null && ls "$outside" | grep -qv disk.img; then
        it_fail "swtpm wrote TPM state outside the bundle"
        return 1
    fi
    kill "$swtpm_pid" 2>/dev/null || true
    wait "$swtpm_pid" 2>/dev/null || true
    echo "qemu-sandbox: swtpm kept no TPM state outside the bundle"

    sb swtpm "$runtime/bin/swtpm" socket --tpm2 --tpmstate dir="$bundle/tpm" --ctrl type=unixio,path="$run/tpm.sock" \
        --log file="$run/swtpm.log" &
    swtpm_pid=$!
    it_wait_for 10 test -S "$run/tpm.sock" || it_fail "sandboxed swtpm did not open its socket" || return 1

    sb qemu "$runtime/bin/qemu-system-aarch64" -L "$runtime/share/qemu" -machine virt -accel hvf -cpu host -m 1024 \
        -nodefaults -display none -serial file:"$run/serial.log" -qmp unix:"$run/qmp.sock",server=on,wait=off \
        -drive if=pflash,format=raw,readonly=on,file="$bundle/code.fd" -drive if=pflash,format=raw,file="$bundle/vars.fd" \
        -chardev socket,id=chrtpm,path="$run/tpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis-device,tpmdev=tpm0,ppi=off -device ramfb -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        2>"$run/qemu.err" &
    qemu_pid=$!
    it_wait_for 60 grep -aqs "UEFI Interactive Shell" "$run/serial.log" ||
        { cat "$run/qemu.err"; it_fail "sandboxed QEMU did not reach the UEFI shell"; return 1; }
    tpm=$(qmp "$run/qmp.sock" query-tpm | jq -r '[.[].id] | join(",")')
    [[ $tpm == tpm0 ]] || it_fail "query-tpm: '$tpm'" || return 1
    [[ -n $(ls "$bundle/tpm") ]] || it_fail "swtpm wrote no state into the bundle" || return 1
    echo "qemu-sandbox: sandboxed QEMU at the UEFI shell under HVF with the sandboxed TPM"
    qmp "$run/qmp.sock" quit >/dev/null || true
    it_wait_exit "$qemu_pid" 10 || it_fail "QEMU did not quit" || return 1

    # QEMU may not open a file outside the bundle and run directory.
    sb qemu "$runtime/bin/qemu-system-aarch64" -machine virt -accel hvf -cpu host -m 256 -nodefaults -display none \
        -drive if=none,id=x,format=raw,readonly=on,file="$outside/disk.img" -device virtio-blk-pci,drive=x -S \
        >/dev/null 2>"$run/deny.err" &
    qemu_pid=$!
    sleep 3
    kill "$qemu_pid" 2>/dev/null || true
    grep -qiE "Operation not permitted|Permission denied" "$run/deny.err" ||
        { cat "$run/deny.err"; it_fail "QEMU opened a file outside the bundle"; return 1; }
    echo "qemu-sandbox: QEMU denied outside the bundle ($(head -1 "$run/deny.err" | sed 's/.*: //' | cut -c1-60))"
    return 0
}
