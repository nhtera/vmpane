# Omarchy from its arm64 ISO with no clicks (OmarchyInstall): the catalog's ISO (sha256-checked, 5.7 GB, downloaded
# once into ~/VMPaneItest/downloads) boots as install media with the seed the stand-in tool writes (the seed is
# private: 0600 in a 0700 folder outside current/, holding the password's hash only); the installer runs by itself;
# the helper sees the boot loader land, removes the seed's data and reports the install complete; the VM restarts in
# place into the installed system (its login on the serial console, under the VM's host name); at the next stop the
# ISO and the seed's device leave the config.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=omarchy-install

scenario_run() {
    local work iso b pid socket config
    iso=$(it_catalog_iso omarchy-4.5.0) || { it_fail "cannot get the Omarchy ISO"; return 1; }
    work=$(mktemp -d /tmp/vp-omarchy.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    b="$VMPANE_SUPPORT_DIR/VMs/Omarchy.vmpane"
    config="$b/config.json"
    it_create_bundle "$b" linux '.name = "Omarchy itest" | .cpu.count = 4 | .memory.mib = 4096 | .disks[0].sizeGiB = 16
        | .removable += [{id: "install", path: "'"$iso"'", bus: "usb"}] | .install = {media: "install"}'
    mkfile -n 16g "$b/current/disk.img"
    printf '%s' "vmpane-itest-omarchy" | "$VMPANE_ITEST_POLICY" seed-omarchy "$b" vmpane || { it_fail "the seed failed"; return 1; }
    jq -e '.install.media == "install" and .install.cloudInit == "cidata" and (.removable | map(.id)) == ["install", "cidata"]
        and ([.portForwards[] | select(.guestPort == 22)] | length) == 0' "$config" >/dev/null \
        || { it_fail "the config has no seed record, or an SSH forward without a key"; return 1; }
    [[ $(stat -f %Lp "$b/install/cidata.iso") == 600 && $(stat -f %Lp "$b/install/cidata") == 700 ]] \
        || { it_fail "the seed is not private"; return 1; }
    grep -q '"\$6\$' "$b/install/cidata/user_credentials.json" && ! grep -q vmpane-itest-omarchy "$b/install/cidata/user_credentials.json" \
        || { it_fail "the seed holds more than the password's hash"; return 1; }
    [[ ! -e $b/install/cidata/authorized_keys ]] || { it_fail "a key file without a key"; return 1; }

    pid=$(it_start_helper "$b") || return 1
    socket=$(it_socket "$b")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "the VM did not start"; return 1; }
    local start=$SECONDS
    # The install: the seed's data goes when the helper sees the boot loader installed (the ISO is read at ~100 MB/s
    # from the Mac's disk; the install itself takes about a minute).
    it_wait_for 900 bash -c "[[ ! -e '$b/install/cidata' ]]" || { it_fail "the install did not finish in 15 min (seed still there)"; return 1; }
    ! grep -q user_credentials "$b/install/cidata.iso" || { it_fail "the seed's ISO still holds the seed"; return 1; }
    echo "omarchy-install: installed after $((SECONDS - start)) s"
    # The installed system boots in place, under the VM's host name.
    it_wait_for 240 grep -a -q "omarchy-itest login:" "$b/logs/serial.log" \
        || { it_fail "the installed system did not boot (no login prompt on the serial console)"; return 1; }
    echo "omarchy-install: Omarchy up after $((SECONDS - start)) s"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || { it_fail "the VM did not stop"; return 1; }
    it_wait_for 30 bash -c "jq -e '.install == null and (.removable | length) == 0' '$config' >/dev/null && [[ ! -e '$b/install/cidata.iso' ]]" \
        || { it_fail "the ISO or the seed's device stayed after the stop"; return 1; }
    echo "omarchy-install: ISO and seed detached at the stop"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=
    return 0
}
