#!/bin/zsh

set -eu
set -o pipefail

readonly PROJECT="${0:A:h:h}/CodexWatch.xcodeproj"
readonly DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
export DEVELOPER_DIR

setting() {
    local target="$1"
    local configuration="$2"
    local key="$3"
    /usr/bin/xcodebuild \
        -project "$PROJECT" \
        -target "$target" \
        -configuration "$configuration" \
        -showBuildSettings 2>/dev/null \
        | /usr/bin/awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }'
}

for configuration in Debug Release; do
    ios_team="$(setting CodexWatch "$configuration" DEVELOPMENT_TEAM)"
    watch_team="$(setting 'CodexWatch Watch App' "$configuration" DEVELOPMENT_TEAM)"
    ios_bundle="$(setting CodexWatch "$configuration" PRODUCT_BUNDLE_IDENTIFIER)"
    watch_bundle="$(setting 'CodexWatch Watch App' "$configuration" PRODUCT_BUNDLE_IDENTIFIER)"
    companion_bundle="$(setting 'CodexWatch Watch App' "$configuration" INFOPLIST_KEY_WKCompanionAppBundleIdentifier)"
    ios_build="$(setting CodexWatch "$configuration" CURRENT_PROJECT_VERSION)"
    watch_build="$(setting 'CodexWatch Watch App' "$configuration" CURRENT_PROJECT_VERSION)"
    independent="$(setting 'CodexWatch Watch App' "$configuration" INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp)"
    standalone_team="$(setting 'CodexWatch Standalone' "$configuration" DEVELOPMENT_TEAM)"
    standalone_bundle="$(setting 'CodexWatch Standalone' "$configuration" PRODUCT_BUNDLE_IDENTIFIER)"
    standalone_build="$(setting 'CodexWatch Standalone' "$configuration" CURRENT_PROJECT_VERSION)"
    watch_only="$(setting 'CodexWatch Standalone' "$configuration" INFOPLIST_KEY_WKWatchOnly)"
    standalone_companion="$(setting 'CodexWatch Standalone' "$configuration" INFOPLIST_KEY_WKCompanionAppBundleIdentifier)"

    [[ -n "$ios_team" && "$ios_team" == "$watch_team" ]] || {
        echo "$configuration: iPhone and Watch development teams differ" >&2
        exit 1
    }
    [[ -n "$ios_bundle" && "$companion_bundle" == "$ios_bundle" ]] || {
        echo "$configuration: WKCompanionAppBundleIdentifier does not match the iPhone app" >&2
        exit 1
    }
    [[ "$watch_bundle" == "$ios_bundle".* ]] || {
        echo "$configuration: Watch bundle identifier is outside the Companion hierarchy" >&2
        exit 1
    }
    [[ -n "$ios_build" && "$ios_build" == "$watch_build" ]] || {
        echo "$configuration: iPhone and Watch build numbers differ" >&2
        exit 1
    }
    [[ "$independent" == "YES" ]] || {
        echo "$configuration: independent Watch operation is disabled" >&2
        exit 1
    }
    [[ "$standalone_team" == "$watch_team" ]] || {
        echo "$configuration: standalone Watch development team differs" >&2
        exit 1
    }
    [[ "$standalone_build" == "$watch_build" ]] || {
        echo "$configuration: standalone Watch build number differs" >&2
        exit 1
    }
    [[ "$watch_only" == "YES" ]] || {
        echo "$configuration: standalone target is not marked WKWatchOnly" >&2
        exit 1
    }
    [[ -z "$standalone_companion" ]] || {
        echo "$configuration: standalone target is still linked to an iPhone companion" >&2
        exit 1
    }
    [[ -n "$standalone_bundle" && "$standalone_bundle" != "$watch_bundle" ]] || {
        echo "$configuration: standalone Watch bundle identity is not independent" >&2
        exit 1
    }
done

echo "Companion and Watch-only packaging validation passed"
