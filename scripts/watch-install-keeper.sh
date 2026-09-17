#!/bin/zsh

set -u
set -o pipefail

readonly WATCH_UDID="${CODEXWATCH_WATCH_UDID:-69E6D1B6-CD0A-5908-BA1D-7A87C58060E2}"
readonly BUNDLE_ID="com.rgferreira.CodexWatch.watchkitapp"
readonly XCODE_PATH="${CODEXWATCH_XCODE_PATH:-/Applications/Xcode-27.app}"
readonly SOURCE_DIR="${CODEXWATCH_SOURCE_DIR:-$HOME/Library/Application Support/CodexWatch/StableSource}"
readonly STABLE_APP="${CODEXWATCH_STABLE_APP:-$HOME/Library/Application Support/CodexWatch/StableBuild/CodexWatch Watch App.app}"
readonly BUILD_ROOT="${CODEXWATCH_BUILD_ROOT:-/Volumes/CORSAIR/Developer/DeviceBuilds/CodexWatch-maintained}"
readonly PROFILE_DIR="${CODEXWATCH_PROFILE_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
readonly STATE_DIR="$HOME/Library/Application Support/CodexWatch/InstallKeeper"
readonly LOG_DIR="$HOME/Library/Logs/CodexWatch"
readonly LOG_FILE="$LOG_DIR/watch-install-keeper.log"
readonly LOCK_DIR="$STATE_DIR/run.lock"
readonly FORCE_INSTALL="${1:-}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

if [[ -f "$LOG_FILE" ]] && (( $(/usr/bin/stat -f '%z' "$LOG_FILE") > 1048576 )); then
    /usr/bin/tail -n 500 "$LOG_FILE" > "$STATE_DIR/watch-install-keeper.log.trimmed"
    /bin/mv "$STATE_DIR/watch-install-keeper.log.trimmed" "$LOG_FILE"
fi

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

if [[ ! -d "$XCODE_PATH/Contents/Developer" ]] || [[ ! -x /usr/bin/xcrun ]]; then
    log "result=skipped reason=xcode_missing"
    exit 0
fi

export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"

watch_is_reachable() {
    local json
    json="$(xcrun devicectl device info apps \
        --device "$WATCH_UDID" \
        --bundle-id "$BUNDLE_ID" \
        --timeout 12 \
        --json-output - 2>/dev/null)" || return 1
    /usr/bin/python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("info", {}).get("outcome") == "success" else 1)' \
        <<< "$json" 2>/dev/null
}

watch_has_app() {
    local json
    json="$(xcrun devicectl device info apps \
        --device "$WATCH_UDID" \
        --bundle-id "$BUNDLE_ID" \
        --timeout 12 \
        --json-output - 2>/dev/null)" || return 1
    /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("info", {}).get("outcome") == "success" and len(d.get("result", {}).get("apps", [])) == 1 else 1)' \
        <<< "$json" 2>/dev/null
}

profile_expiration_epoch() {
    local app="$1"
    local value
    [[ -f "$app/embedded.mobileprovision" ]] || return 1
    value="$(/usr/bin/security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null \
        | /usr/bin/plutil -extract ExpirationDate raw - 2>/dev/null)" || return 1
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null
}

app_is_signed_and_current() {
    local app="$1"
    local expiration
    [[ -d "$app" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
    expiration="$(profile_expiration_epoch "$app")" || return 1
    (( expiration > $(date +%s) + 300 ))
}

retire_expired_profiles() {
    local profile application_id expiration backup_dir
    backup_dir="$STATE_DIR/expired-profiles"
    mkdir -p "$backup_dir"

    for profile in "$PROFILE_DIR"/*.mobileprovision(N); do
        application_id="$(/usr/bin/security cms -D -i "$profile" 2>/dev/null \
            | /usr/bin/plutil -extract Entitlements.application-identifier raw - 2>/dev/null)" || continue
        [[ "$application_id" == *".$BUNDLE_ID" ]] || continue
        expiration="$(/usr/bin/security cms -D -i "$profile" 2>/dev/null \
            | /usr/bin/plutil -extract ExpirationDate raw - 2>/dev/null)" || continue
        expiration="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null)" || continue
        if (( expiration <= $(date +%s) )); then
            /bin/mv "$profile" "$backup_dir/$(date -u '+%Y%m%dT%H%M%SZ')-$(basename "$profile")"
            log "operation=profile_retire result=success"
        fi
    done
}

build_fresh_app() {
    local product
    [[ -d "$SOURCE_DIR/CodexWatch.xcodeproj" ]] || {
        log "operation=build result=skipped reason=stable_source_missing"
        return 1
    }
    [[ -d "${BUILD_ROOT:h}" ]] || {
        log "operation=build result=skipped reason=external_build_volume_missing"
        return 1
    }

    retire_expired_profiles
    mkdir -p "$BUILD_ROOT"
    log "operation=build result=started"
    if ! xcodebuild \
        -project "$SOURCE_DIR/CodexWatch.xcodeproj" \
        -target 'CodexWatch Watch App' \
        -configuration Release \
        -sdk watchos \
        -allowProvisioningUpdates \
        SYMROOT="$BUILD_ROOT/Build" \
        OBJROOT="$BUILD_ROOT/Intermediates" \
        build >> "$LOG_FILE" 2>&1; then
        log "operation=build result=failed"
        return 1
    fi

    product="$BUILD_ROOT/Build/Release-watchos/CodexWatch Watch App.app"
    app_is_signed_and_current "$product" || {
        log "operation=build result=failed reason=invalid_or_expired_product"
        return 1
    }

    rm -rf "$STATE_DIR/StableBuild.new"
    mkdir -p "$STATE_DIR/StableBuild.new"
    /usr/bin/ditto "$product" "$STATE_DIR/StableBuild.new/CodexWatch Watch App.app"
    rm -rf "${STABLE_APP:h}.previous"
    if [[ -d "${STABLE_APP:h}" ]]; then
        /bin/mv "${STABLE_APP:h}" "${STABLE_APP:h}.previous"
    fi
    /bin/mv "$STATE_DIR/StableBuild.new" "${STABLE_APP:h}"
    log "operation=build result=success"
}

install_app() {
    log "operation=install result=started"
    if ! xcrun devicectl device install app \
        --device "$WATCH_UDID" \
        "$STABLE_APP" \
        --timeout 60 >> "$LOG_FILE" 2>&1; then
        log "operation=install result=failed"
        return 1
    fi
    if watch_has_app; then
        log "operation=install result=success"
        return 0
    fi
    log "operation=install result=failed reason=verification"
    return 1
}

if ! watch_is_reachable; then
    log "result=skipped reason=watch_unreachable"
    exit 0
fi

if [[ "$FORCE_INSTALL" != "--force" ]] && watch_has_app && app_is_signed_and_current "$STABLE_APP"; then
    log "result=healthy"
    exit 0
fi

if ! app_is_signed_and_current "$STABLE_APP"; then
    build_fresh_app || exit 0
fi

install_app || exit 0
