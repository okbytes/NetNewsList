#!/bin/bash
# Install or update NetNewsList on the work computer from this repo's latest release, or from <tag>.
# Usage: install-work-mac.sh [tag]
#
# Needs only `gh`, logged in. On a Mac without a checkout:
#   gh api repos/okbytes/NetNewsList/contents/scripts/install-work-mac.sh \
#     -H "Accept: application/vnd.github.raw" | bash -s [tag]
# It replaces the work copy where it is (/Applications or ~/Applications), or installs it in
# ~/Applications, and never touches the everyday copy (eitherslice.NetNewsList) on a home Mac.
# Releases have no CloudKit API token in them: the app asks for it once and keeps it.
set -euo pipefail

REPO="okbytes/NetNewsList"
BUNDLE_ID="eitherslice.NetNewsList.Web"

fail() {
    echo "✗ $1" >&2
    exit 1
}

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

command -v gh >/dev/null || fail "Install the GitHub CLI (brew install gh), then run: gh auth login"

DEST="$HOME/Applications/NetNewsList.app"
if [ "$(bundle_id /Applications/NetNewsList.app)" = "$BUNDLE_ID" ]; then
    DEST="/Applications/NetNewsList.app"
fi
existing="$(bundle_id "$DEST")"
[ -z "$existing" ] || [ "$existing" = "$BUNDLE_ID" ] ||
    fail "$DEST is $existing, not the work copy. This script installs only the work copy."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Downloading ${1:-the latest release}…"
gh release download ${1:+"$1"} --repo "$REPO" --pattern 'NetNewsList-Work-*.zip' --dir "$WORK"
ZIP="$(ls "$WORK"/NetNewsList-Work-*.zip)"
ditto -x -k "$ZIP" "$WORK"
APP="$WORK/NetNewsList.app"
[ "$(bundle_id "$APP")" = "$BUNDLE_ID" ] || fail "The download isn't the work copy."
spctl --assess --type execute "$APP" || fail "The download is not a notarized build."
RELEASE="$(basename "$ZIP" .zip)"

if pgrep -qf "$DEST/Contents/MacOS/"; then
    echo "▸ Quitting the running copy…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do
        pgrep -qf "$DEST/Contents/MacOS/" || break
        sleep 0.1
    done
    pgrep -qf "$DEST/Contents/MacOS/" && fail "NetNewsList didn't quit. Quit it and run this again."
fi

echo "▸ Installing $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST" || fail "Couldn't replace $DEST."
ditto "$APP" "$DEST"
open "$DEST"
# Lists Save to NetNewsList in the Services menu now, rather than at the next login.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
echo "✓ NetNewsList for the work computer (${RELEASE#NetNewsList-Work-}) is running"
