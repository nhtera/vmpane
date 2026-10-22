# Zero-click Linux from the catalog's cloud images (agent edge, Phase 04), each made as the wizard makes it
# (VMCreator through the itest stand-in tool): the image is downloaded, checked and converted once (cache in
# ~/VMPaneItest/cloud), the VM's disk is a clone of it grown to 16 GiB, and a cloud-init seed sets up the user, SSH and
# VMPane's guest tools on the first boot, with no clicks. Then:
#   - the guest tools connect (the time from start is printed: < 2 min once the image is cached);
#   - the seed's data is gone from the bundle at once, its device from the config at the next stop, and the guest
#     keeps no copy of the user data;
#   - the root file system was grown; the user exists, is an administrator, and SSH takes its key on the forward,
#     which listens on 127.0.0.1 only;
#   - before boot the seed is 0600 in a 0700 folder outside current/ (so no snapshot holds it).
# Distros: $VMPANE_ITEST_CLOUD_DISTROS (default "ubuntu debian fedora"). Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=linux-cloud
IT_CLOUD_CACHE="$HOME/VMPaneItest/cloud"

it_cloud_one() {
    local distro=$1 image work bundle pid socket key started ready port config status
    image=$(jq -r --arg d "$distro" '.images[] | select(.kind == "cloudImage" and .distro == $d) | .id' \
        "$VMPANE_ROOT/Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/linux-catalog.json")
    [[ -n $image ]] || { it_fail "no $distro cloud image in the catalog"; return 1; }
    work=$(mktemp -d /tmp/vp-cloud.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs" "$IT_CLOUD_CACHE"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 60; rm -rf "$work"; trap - RETURN; true' RETURN
    ssh-keygen -q -t ed25519 -N '' -C vmpane-itest -f "$work/key"
    bundle=$(printf '%s' "vmpane-itest-cloud" | "$VMPANE_ITEST_POLICY" create-cloud "$image" "Cloud $distro" vmpane \
        "$APP/Contents/Helpers/qemu/bin/qemu-img" "$IT_CLOUD_CACHE" --ssh-key "$(cat "$work/key.pub")") \
        || { it_fail "$distro: the create failed"; return 1; }
    config="$bundle/config.json"
    jq -e '.install.cloudInit == "cidata" and (.removable | map(.id) | index("cidata"))
        and (.portForwards | map(select(.guestPort == 22 and .hostAddress == "127.0.0.1")) | length == 1)' "$config" >/dev/null \
        || { it_fail "$distro: the config has no seed or SSH forward"; return 1; }
    [[ $(stat -f %Lp "$bundle/install/cidata.iso") == 600 && $(stat -f %Lp "$bundle/install/cidata") == 700 ]] \
        || { it_fail "$distro: the seed is not private"; return 1; }
    [[ ! -e $bundle/current/cidata.iso ]] || { it_fail "$distro: the seed is in current/"; return 1; }
    grep -q '^    passwd: "\$6\$' "$bundle/install/cidata/user-data" && ! grep -q vmpane-itest-cloud "$bundle/install/cidata/user-data" \
        || { it_fail "$distro: the seed holds more than the password's hash"; return 1; }

    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    started=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "$distro: vm.start failed" || return 1
    it_wait_for 600 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status 2>/dev/null | jq -e .connected >/dev/null" \
        || { it_screenshot "$socket" "$VMPANE_ROOT/itest/results/linux-cloud-$distro-failure.png" 1600; it_fail "$distro: the guest tools never connected"; return 1; }
    ready=$((SECONDS - started))
    echo "linux-cloud: $distro ready (guest tools connected) $ready s after start"
    # The seed's data goes at once (its ISO is an empty placeholder until the VM stops), the device at the next stop.
    it_wait_for 30 bash -c "[[ ! -e '$bundle/install/cidata' ]] && ! grep -q cloud-config '$bundle/install/cidata.iso'" \
        || { it_fail "$distro: the seed is still there after the first boot"; return 1; }
    X="/usr/bin/python3 $VMPANE_ROOT/itest/lib/agent_exec.py $socket"
    $X 'ls /var/lib/cloud/instances/*/user-data.txt* /var/lib/cloud/instances/*/cloud-config.txt 2>/dev/null' | grep -q . \
        && { it_fail "$distro: the guest keeps cloud-init's user-data"; return 1; }
    local size groups
    size=$($X "df -BG --output=size / | tail -1 | tr -dc 0-9")
    ((size >= 12)) || { it_fail "$distro: the root file system is ${size} GiB (not grown)"; return 1; }
    groups=$($X 'id -nG vmpane')
    [[ $groups == *sudo* || $groups == *wheel* ]] || { it_fail "$distro: vmpane is not an administrator ($groups)"; return 1; }
    port=$(jq -r '.portForwards[] | select(.guestPort == 22) | .hostPort' "$config")
    it_rpc "$socket" vm.ports.list | jq -e --argjson p "$port" '.rules[] | select(.hostPort == $p and .hostAddress == "127.0.0.1" and .status == "listening")' >/dev/null \
        || { it_fail "$distro: the SSH forward is not listening on 127.0.0.1"; return 1; }
    it_wait_for 60 ssh -q -i "$work/key" -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 vmpane@127.0.0.1 true || { it_fail "$distro: ssh with the key failed"; return 1; }
    echo "linux-cloud: $distro: seed gone, ${size} GiB root, vmpane in ($groups), ssh on 127.0.0.1:$port"
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 90 bash -c "! jq -e '.install, (.removable[] | select(.id == \"cidata\"))' '$config' >/dev/null && [[ ! -e '$bundle/install/cidata.iso' ]]" \
        || { it_fail "$distro: the seed's device stayed after the VM stopped"; return 1; }
}

scenario_run() {
    local distro
    for distro in ${VMPANE_ITEST_CLOUD_DISTROS:-ubuntu debian fedora}; do
        it_cloud_one "$distro" || return 1
    done
}
