# The app driven like a user (Phase 08): the XCUITest suite in UITests/ (empty library, the wizard's Linux
# path, accessibility audits of the library and wizard). Each test runs the app on its own empty support
# directory, never the user's library. Needs an unlocked GUI session; the first run asks to allow UI
# automation (System Settings > Privacy & Security), once per Mac.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=ui-smoke

scenario_run() {
    if ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "ui-smoke: skipped: this Mac is locked (UI tests need the screen)" >&2
        return 77
    fi
    local work log
    work=$(mktemp -d /tmp/vp-ui.XXXXXX)
    trap 'set +e; rm -rf "${work:-/nonexistent}"; true' RETURN
    log="$work/xcodebuild.log"
    if ! xcodebuild test -project "$VMPANE_ROOT/VMPane.xcodeproj" -scheme VMPane -destination 'platform=macOS' \
        -only-testing:VMPaneUITests -derivedDataPath "$work/dd" -resultBundlePath "$work/ui.xcresult" >"$log" 2>&1; then
        grep -E "error:|failed|Test Case .* failed" "$log" | tail -20 >&2
        it_fail "UI tests failed"
        return 1
    fi
    grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^/ui-smoke: /'
}
