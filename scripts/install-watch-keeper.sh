#!/bin/zsh

set -eu
set -o pipefail

readonly REPO_DIR="${0:A:h:h}"
readonly SOURCE_REPO="${CODEXWATCH_SOURCE_REPO:-$REPO_DIR}"
readonly SUPPORT_DIR="$HOME/Library/Application Support/CodexWatch"
readonly SOURCE_DIR="$SUPPORT_DIR/StableSource"
readonly BUILD_DIR="$SUPPORT_DIR/StableBuild"
readonly KEEPER_DIR="$SUPPORT_DIR/InstallKeeper"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.rgferreira.CodexWatchInstallKeeper.plist"
readonly LABEL="com.rgferreira.CodexWatchInstallKeeper"
readonly SOURCE_APP="/Volumes/CORSAIR/Developer/DeviceBuilds/CodexWatch-0.7-41-watch-release/Build/Release-watchos/CodexWatch Watch App.app"

mkdir -p "$SUPPORT_DIR" "$KEEPER_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/CodexWatch"

rm -rf "$SOURCE_DIR.new"
mkdir -p "$SOURCE_DIR.new"
/usr/bin/rsync -a --delete --exclude='.git/' --exclude='build/' \
    "$SOURCE_REPO/" "$SOURCE_DIR.new/"
git -C "$SOURCE_REPO" rev-parse HEAD > "$SOURCE_DIR.new/stable-source-commit"
rm -rf "$SOURCE_DIR.previous"
if [[ -d "$SOURCE_DIR" ]]; then
    mv "$SOURCE_DIR" "$SOURCE_DIR.previous"
fi
mv "$SOURCE_DIR.new" "$SOURCE_DIR"

rm -rf "$BUILD_DIR.new"
mkdir -p "$BUILD_DIR.new"
/usr/bin/ditto "$SOURCE_APP" "$BUILD_DIR.new/CodexWatch Watch App.app"
rm -rf "$BUILD_DIR.previous"
if [[ -d "$BUILD_DIR" ]]; then
    mv "$BUILD_DIR" "$BUILD_DIR.previous"
fi
mv "$BUILD_DIR.new" "$BUILD_DIR"

/usr/bin/ditto "$REPO_DIR/scripts/watch-install-keeper.sh" "$KEEPER_DIR/watch-install-keeper.sh"
chmod 700 "$KEEPER_DIR/watch-install-keeper.sh"

/usr/bin/python3 - "$LAUNCH_AGENT" "$KEEPER_DIR/watch-install-keeper.sh" <<'PY'
import plistlib
import sys

path, program = sys.argv[1:]
payload = {
    "Label": "com.rgferreira.CodexWatchInstallKeeper",
    "ProgramArguments": [program],
    "RunAtLoad": True,
    "StartInterval": 10800,
    "ProcessType": "Background",
    "LowPriorityIO": True,
    "StandardOutPath": str(__import__("pathlib").Path.home() / "Library/Logs/CodexWatch/watch-install-keeper.launchd.log"),
    "StandardErrorPath": str(__import__("pathlib").Path.home() / "Library/Logs/CodexWatch/watch-install-keeper.launchd.log"),
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=True)
PY
chmod 600 "$LAUNCH_AGENT"

/bin/launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
/bin/launchctl enable "gui/$(id -u)/$LABEL"
/bin/launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "CodexWatch install keeper enabled."
