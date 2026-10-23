# The library with a VM in it, driven like a user (UITests/LibraryUITests): a stopped clone of the golden Linux VM
# (never started) in an empty support folder; its row, the inspector's tabs and actions, the filters, and the
# accessibility audit (VMPANE_ITEST_SKIP_AUDITS=1 leaves the audit out). Needs an unlocked GUI session.
# Sourced by scripts/itest.sh with $APP set.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=library-ui

scenario_run() {
    if ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "library-ui: skipped: this Mac is locked (UI tests need the screen)" >&2
        return 77
    fi
    local golden work test
    golden=$(it_golden_linux) || return 1
    work=$(mktemp -d /tmp/vp-lib.XXXXXX)
    trap 'rm -rf "$work"; trap - RETURN' RETURN
    mkdir -p "$work/s/VMs"
    it_clone_bundle "$golden" "$work/s/VMs/Ubuntu.vmpane"
    jq '.name = "Ubuntu 26.04"' "$work/s/VMs/Ubuntu.vmpane/config.json" >"$work/config.json"
    mv "$work/config.json" "$work/s/VMs/Ubuntu.vmpane/config.json"
    for test in testALibraryWithAVM testALibraryWithAVMPassesTheAccessibilityAudit; do
        if [[ $test == *Audit && ${VMPANE_ITEST_SKIP_AUDITS:-0} == 1 ]]; then
            echo "library-ui: the audit skipped (VMPANE_ITEST_SKIP_AUDITS)"
            continue
        fi
        if ! TEST_RUNNER_VMPANE_ITEST_LIBRARY="$work/s" it_ui_tests "VMPaneUITests/LibraryUITests/$test" "$work/$test.log"; then
            grep -E "error:|failed" "$work/$test.log" | tail -20 >&2
            it_fail "UI test $test failed"
            return 1
        fi
        grep -q "Test Case.*$test\]' passed" "$work/$test.log" || { it_fail "UI test $test did not run (skipped?)"; return 1; }
        echo "library-ui: $test passed"
    done
}
