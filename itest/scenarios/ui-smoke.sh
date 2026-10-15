# The app driven like a user (Phase 08): the XCUITest suite in UITests/ (empty library, the wizard's Linux
# path, accessibility audits of the library, the wizard and Settings), then the audit of a running Linux VM's window
# and its settings sheet, and the VM's menu bar and Quit. Each test runs the app on its own empty support directory, never the user's library. Needs an unlocked GUI session; the first run asks to allow UI
# automation (System Settings > Privacy & Security), once per Mac.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=ui-smoke

scenario_run() {
    if ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "ui-smoke: skipped: this Mac is locked (UI tests need the screen)" >&2
        return 77
    fi
    local ui log work bundle pid socket
    ui=$(mktemp -d /tmp/vp-ui.XXXXXX)
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$ui" "${work:-/nonexistent}"; true' RETURN
    log="$ui/xcodebuild.log"
    if ! it_ui_tests VMPaneUITests "$log" "$ui/ui.xcresult"; then
        grep -E "error:|failed|Test Case .* failed" "$log" | tail -20 >&2
        it_fail "UI tests failed"
        return 1
    fi
    grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^/ui-smoke: /'

    # The Mac's available memory as the helper sees it (VMPANE_TEST_AVAILABLE_MIB_FILE): plenty, until the low-memory
    # test below.
    export VMPANE_TEST_AVAILABLE_MIB_FILE="$ui/available-mib"
    echo 1000000 >"$VMPANE_TEST_AVAILABLE_MIB_FILE"
    it_boot_linux_clone || return 1  # (sets work, bundle, pid, socket)
    TEST_RUNNER_VMPANE_ITEST_AUDIT=1 it_ui_vm_window VMPaneUITests/VMWindowUITests/testVMWindowPassesTheAccessibilityAudit || return 1
    echo "ui-smoke: a running VM's window and its settings pass the accessibility audit"
    # (testDockMenuActsOnTheVM needs a Dock that shows: an auto-hidden one does not come up for the test. By hand.)
    TEST_RUNNER_VMPANE_ITEST_DOCK=1 it_ui_vm_window VMPaneUITests/VMWindowUITests/testQuitAsksWhileTheVMRuns || return 1
    [[ $(it_state "$bundle") == running ]] || it_fail "the VM is not running after a cancelled Quit" || return 1
    echo "ui-smoke: the VM's app has a menu bar; Quit asks while the VM runs"
    # Nearly out of memory: the window warns; the test shuts the VM down and starts it again from its window.
    echo 512 >"$VMPANE_TEST_AVAILABLE_MIB_FILE"
    TEST_RUNNER_VMPANE_ITEST_LOW_MEMORY=1 it_ui_vm_window VMPaneUITests/VMWindowUITests/testLowMemoryWarnsAndAsksBeforeAStart || return 1
    [[ $(it_state "$bundle") == running ]] || it_fail "Start Anyway did not start the VM" || return 1
    echo "ui-smoke: a Mac low on memory: the VM's window warns, and Start asks first"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
}
