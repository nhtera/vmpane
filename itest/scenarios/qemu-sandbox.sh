# QEMU and swtpm under their sandbox profiles (the helper's VMPaneQEMU resources, applied with sandbox-exec), from a
# runtime copy laid out like runtime/<version>/qemu: QEMU's libraries read the Mac's name servers (slirp's DNS
# proxy) and iconv tables like an unsandboxed process; swtpm keeps its TPM state in the VM bundle and listens
# in the run directory; QEMU boots the shipped firmware to the UEFI shell with HVF, the TPM, CoreAudio sound,
# a SPICE socket and a port forward, and reports no device it could not start; each is
# denied a file outside its bundle and run directory. With VMPANE_SIGN_IDENTITY set to a real identity the
# copy is first signed like a release (hardened runtime, scripts/sign.sh --qemu-only), proving the profiles
# against product-signed binaries.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=qemu-sandbox

qmp() { /usr/bin/python3 -I "$VMPANE_ROOT/itest/lib/qmp.py" "$@"; }

scenario_run() {
    local bin share work runtime bundle run outside swtpm_pid qemu_pid tpm profiles aux
    # The profiles the helper ships, or the sources when testing a bundle without an app.
    profiles=$APP/Contents/Helpers/VMPaneVM.app/Contents/Resources/VMPaneKit_VMPaneQEMU.bundle/Contents/Resources/Sandbox
    [[ -f $profiles/qemu.sb ]] || profiles=$VMPANE_ROOT/Packages/VMPaneKit/Sources/VMPaneQEMU/Sandbox
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
    # The bundle as VMPane lays it out: QEMU may write only under current/, swtpm only current/aux/tpm.
    aux=$bundle/current/aux
    mkdir -p "$runtime" "$aux/tpm" "$run" "$outside"
    ditto "$bin/bin" "$runtime/bin"
    ditto "$bin/lib" "$runtime/lib"
    ditto "$share" "$runtime/share"
    if [[ ${VMPANE_SIGN_IDENTITY:--} != - ]]; then
        "$VMPANE_ROOT/scripts/sign.sh" --qemu-only "$runtime" >/dev/null || it_fail "signing the runtime copy failed" || return 1
        [[ $(codesign -dv "$runtime/bin/qemu-system-aarch64" 2>&1) == *flags=*runtime* ]] ||
            it_fail "no hardened runtime after signing" || return 1
        echo "qemu-sandbox: runtime copy signed with the hardened runtime"
    fi
    cp "$runtime/share/edk2-aarch64-vars-sb.fd" "$aux/efi_vars.fd"
    cp "$runtime/share/edk2-aarch64-code.fd" "$run/efi_code.fd"
    truncate -s 64m "$aux/efi_vars.fd" "$run/efi_code.fd"
    printf 'x%.0s' {1..4096} >"$outside/disk.img"

    sb() {  # sb <profile> <command…>
        local profile=$1
        shift
        TMPDIR=$run sandbox-exec -f "$profiles/$profile.sb" \
            -D BUNDLE="$bundle" -D RUNDIR="$run" -D RUNTIME="$runtime" "$@"
    }

    # QEMU's libraries see the Mac's name servers (slirp's DNS proxy forwards to the first; denied, res_ninit
    # returns 0.0.0.0 and no guest query is answered) and can convert character sets (glib's error messages).
    local probe=$runtime/bin/sandbox-probe want got
    /usr/bin/clang -O "$VMPANE_ROOT/itest/lib/sandbox_probe.c" -lresolv -liconv -o "$probe" ||
        it_fail "could not build the sandbox probe" || return 1
    want=$("$probe")
    got=$(sb qemu "$probe")
    [[ $got == "$want" && $got == *"ns "* && $got != *"ns 0.0.0.0"* && $got == *"iconv ok"* ]] ||
        { printf 'unsandboxed:\n%s\nsandboxed:\n%s\n' "$want" "$got"; it_fail "sandboxed QEMU's libraries see a different Mac"; return 1; }
    echo "qemu-sandbox: sandboxed QEMU reads the Mac's name servers ($(grep -m1 '^ns ' <<<"$got" | cut -c4-)) and iconv tables"

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

    sb swtpm "$runtime/bin/swtpm" socket --tpm2 --tpmstate dir="$aux/tpm" --ctrl type=unixio,path="$run/tpm.sock" \
        --log file="$run/swtpm.log" &
    swtpm_pid=$!
    it_wait_for 10 test -S "$run/tpm.sock" || it_fail "sandboxed swtpm did not open its socket" || return 1

    sb qemu "$runtime/bin/qemu-system-aarch64" -L "$runtime/share/qemu" -machine virt -accel hvf -cpu host -m 1024 \
        -nodefaults -display none -serial file:"$run/serial.log" -qmp unix:"$run/qmp.sock",server=on,wait=off \
        -drive if=pflash,format=raw,readonly=on,file="$run/efi_code.fd" -drive if=pflash,format=raw,file="$aux/efi_vars.fd" \
        -chardev socket,id=chrtpm,path="$run/tpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis-device,tpmdev=tpm0,ppi=off -device ramfb -netdev user,id=n0,hostfwd=tcp:127.0.0.1:47301-:22 -device virtio-net-pci,netdev=n0 \
        -audiodev coreaudio,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
        -spice unix=on,addr="$run/spice.sock",disable-ticketing=on 2>"$run/qemu.err" &
    qemu_pid=$!
    it_wait_for 60 grep -aqs "UEFI Interactive Shell" "$run/serial.log" ||
        { cat "$run/qemu.err"; it_fail "sandboxed QEMU did not reach the UEFI shell"; return 1; }
    tpm=$(qmp "$run/qmp.sock" query-tpm | jq -r '[.[].id] | join(",")')
    [[ $tpm == tpm0 ]] || it_fail "query-tpm: '$tpm'" || return 1
    [[ -n $(ls "$aux/tpm") ]] || it_fail "swtpm wrote no state into the bundle" || return 1
    test -S "$run/spice.sock" || it_fail "no SPICE socket in the run directory" || return 1
    ! grep -qi "could not" "$run/qemu.err" || { cat "$run/qemu.err"; it_fail "QEMU reported a device it could not start"; return 1; }
    ! grep -q "Conversion from character set" "$run/qemu.err" ||
        { head -5 "$run/qemu.err"; it_fail "QEMU could not convert character sets"; return 1; }
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

    # Nor write bundle files outside current/ (config.json, snapshot metadata: parsed by the helper).
    printf 'x%.0s' {1..4096} >"$bundle/config.img"
    sb qemu "$runtime/bin/qemu-system-aarch64" -machine virt -accel hvf -cpu host -m 256 -nodefaults -display none \
        -drive if=none,id=y,format=raw,file="$bundle/config.img" -device virtio-blk-pci,drive=y -S \
        >/dev/null 2>"$run/deny-write.err" &
    qemu_pid=$!
    sleep 3
    kill "$qemu_pid" 2>/dev/null || true
    grep -qiE "Operation not permitted|Permission denied|read-only" "$run/deny-write.err" ||
        { cat "$run/deny-write.err"; it_fail "QEMU opened a bundle file outside current/ for writing"; return 1; }
    echo "qemu-sandbox: QEMU denied writing outside current/ ($(head -1 "$run/deny-write.err" | sed 's/.*: //' | cut -c1-60))"

    # Nor connect to a Unix socket outside its run directory (another VM's or another app's).
    /usr/bin/python3 -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(20)' \
        "$outside/x.sock" &
    local listener=$!
    it_wait_for 5 test -S "$outside/x.sock"
    sb qemu "$runtime/bin/qemu-system-aarch64" -machine virt -accel hvf -cpu host -m 256 -nodefaults -display none -S \
        -chardev socket,id=c0,path="$outside/x.sock" >/dev/null 2>"$run/deny-unix.err" &
    qemu_pid=$!
    sleep 3
    kill "$qemu_pid" "$listener" 2>/dev/null || true
    grep -qiE "Operation not permitted|Permission denied" "$run/deny-unix.err" ||
        { cat "$run/deny-unix.err"; it_fail "QEMU connected to a Unix socket outside its run directory"; return 1; }
    echo "qemu-sandbox: QEMU denied a Unix socket outside its run directory"
    return 0
}
