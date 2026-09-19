#!/bin/zsh

set -euo pipefail

watch_id="${1:-00008310-000A6D3411DA601E}"
label="${2:-snapshot}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
root="${CODEXWATCH_FORENSICS_ROOT:-$HOME/Library/Application Support/CodexWatch/Forensics}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$root/$timestamp-$label"
typeset -gi failures=0

export DEVELOPER_DIR="$developer_dir"
mkdir -p "$destination"

run_capture() {
    local name="$1"
    shift
    if "$@" >"$destination/$name.stdout" 2>"$destination/$name.stderr"; then
        print -r -- 0 >"$destination/$name.exit"
    else
        local exit_code=$?
        print -r -- "$exit_code" >"$destination/$name.exit"
        (( failures += 1 ))
    fi
    return 0
}

run_capture devices xcrun devicectl list devices
run_capture details xcrun devicectl device info details --device "$watch_id" --timeout 30
run_capture lock-state xcrun devicectl device info lockState --device "$watch_id" --timeout 30
run_capture app-current xcrun devicectl device info apps \
    --device "$watch_id" \
    --bundle-id com.rgferreira.CodexWatchCompanion.watchapp \
    --json-output "$destination/app-current.json" \
    --timeout 30
run_capture app-standalone xcrun devicectl device info apps \
    --device "$watch_id" \
    --bundle-id com.rgferreira.CodexWatchStandalone \
    --json-output "$destination/app-standalone.json" \
    --timeout 30
run_capture app-legacy xcrun devicectl device info apps \
    --device "$watch_id" \
    --bundle-id com.rgferreira.CodexWatch.watchkitapp \
    --json-output "$destination/app-legacy.json" \
    --timeout 30
run_capture profiles xcrun devicectl device profile list \
    --device "$watch_id" \
    --type provisioning \
    --json-output "$destination/profiles.json" \
    --timeout 30
run_capture processes xcrun devicectl device info processes \
    --device "$watch_id" \
    --json-output "$destination/processes.json" \
    --timeout 30

(
    cd "$destination"
    shasum -a 256 -- * > SHA256SUMS
)

print -r -- "$destination"
(( failures == 0 ))
