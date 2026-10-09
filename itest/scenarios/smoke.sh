# Smoke: the app launches, stays up, and exits when asked to quit.
# Sourced by scripts/itest.sh with $APP set to the .app under test.

scenario_run() {
    local exe pid
    exe="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
    "$exe" >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true

    # Alive after 3 s means no crash at launch.
    sleep 3
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "smoke: app exited during launch" >&2
        return 1
    fi

    kill -TERM "$pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    echo "smoke: app did not quit within 5 s" >&2
    kill -KILL "$pid" 2>/dev/null || true
    return 1
}
