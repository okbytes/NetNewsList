#!/bin/bash
# Build NetNewsList (Release, development-signed) and install it as ~/Applications/NetNewsList.app.
# Usage: scripts/install-mac.sh [--no-pull]
#
# This is the copy for everyday use. The Debug build Xcode runs is "NetNewsList Dev"; both read
# and write the same iCloud data (the CloudKit Development environment), and only this one answers
# netnewslist:// links. Rerun after pulling to update it, and
# once a year after a new Apple Development certificate, or the app stops launching.
#
# The first install copies NetNewsList Dev's local data into the new app before it's used: the
# database (iCloud doesn't carry each page's saved date, so a fresh copy would show every page as
# saved today), offline images, backups, settings and the X sign-in. NetNewsList Dev keeps its own
# copy. The terminal needs access to other apps' data for that; allow it when macOS asks.
# --no-pull builds the checkout as it is.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="build/ReleaseDerivedData.noindex"
DEST="$HOME/Applications/NetNewsList.app"
BUNDLE_ID="eitherslice.NetNewsList"
DEV_BUNDLE_ID="eitherslice.NetNewsList-DEBUG"
DATA_PATH="Library/Application Support/NetNewsList"
DEV_DATA="$HOME/Library/Containers/$DEV_BUNDLE_ID/Data"
REL_DATA="$HOME/Library/Containers/$BUNDLE_ID/Data"
# Present from the start of a copy until it finishes, so a run that stops partway copies again.
PORT_PENDING="$ROOT/build/install-mac-port-pending"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() {
    echo "✗ $1" >&2
    exit 1
}

is_running() {
    [ "$(osascript -e "application id \"$1\" is running" 2>/dev/null)" = "true" ]
}

# Quits gracefully, so the database is closed cleanly; never kills.
quit_app() {
    is_running "$1" || return 0
    echo "▸ Quitting $2…"
    osascript -e "tell application id \"$1\" to quit" >/dev/null
    for _ in $(seq 1 150); do
        is_running "$1" || return 0
        sleep 0.1
    done
    fail "$2 didn't quit. Quit it and run this again."
}

wait_for() {
    for _ in $(seq 1 300); do
        [ -e "$1" ] && return 0
        sleep 0.1
    done
    fail "Timed out waiting for $1"
}

list_counts() {
    sqlite3 -readonly "$1/$DATA_PATH/Accounts/2_iCloud/DB.sqlite3" \
        "select sum(read = 0) || ' in Queue, ' || sum(read = 1) || ' in Archive' from articles natural join statuses;"
}

security find-identity -p codesigning -v | grep -q '"Apple Development' ||
    fail "No Apple Development certificate. Sign in to Xcode (Settings › Accounts)."

PORT=0
if [ -e "$PORT_PENDING" ] || { [ -e "$DEV_DATA/$DATA_PATH/Accounts" ] && [ ! -e "$REL_DATA/$DATA_PATH/Accounts" ]; }; then
    PORT=1
    ls "$DEV_DATA/$DATA_PATH" >/dev/null 2>&1 ||
        fail "This terminal can't read NetNewsList Dev's data. Allow access to data from other apps when macOS asks, or give the terminal Full Disk Access (System Settings › Privacy & Security), then run this again."
fi

if [ "${1:-}" != "--no-pull" ] && git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    if [ -z "$(git status --porcelain)" ]; then
        echo "▸ Pulling $(git rev-parse --abbrev-ref HEAD)…"
        git pull --ff-only
    else
        echo "▸ Local changes present; building the checkout as it is."
    fi
fi

echo "▸ Building NetNewsList (Release)…"
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire -configuration Release \
    -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=arm64" \
    -allowProvisioningUpdates build -quiet
BUILT="$DERIVED/Build/Products/Release/NetNewsList.app"

quit_app "$BUNDLE_ID" "NetNewsList"
if [ -e "$DEST" ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" = "$BUNDLE_ID" ] ||
        fail "$DEST isn't this app; move it away first."
fi
echo "▸ Installing $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# xcodebuild registers every app it builds; only the installed copy should answer netnewslist:// links.
"$LSREGISTER" -u "$BUILT"
"$LSREGISTER" -f "$DEST"

if [ "$PORT" -eq 1 ]; then
    touch "$PORT_PENDING"
    quit_app "$DEV_BUNDLE_ID" "NetNewsList Dev"
    if [ ! -e "$REL_DATA/$DATA_PATH" ]; then
        # macOS creates an app's container at its first launch. What this launch syncs from
        # iCloud is replaced below.
        echo "▸ Opening NetNewsList once to create its container…"
        open -g -j "$DEST"
        wait_for "$REL_DATA/$DATA_PATH/Accounts"
        sleep 2
        quit_app "$BUNDLE_ID" "NetNewsList"
    fi

    echo "▸ Copying NetNewsList Dev's database, images, backups, settings and X sign-in…"
    rsync -a --delete "$DEV_DATA/$DATA_PATH/" "$REL_DATA/$DATA_PATH/"
    if [ -d "$DEV_DATA/Library/WebKit/WebsiteDataStore" ]; then
        mkdir -p "$REL_DATA/Library/WebKit"
        rsync -a --delete "$DEV_DATA/Library/WebKit/WebsiteDataStore/" "$REL_DATA/Library/WebKit/WebsiteDataStore/"
    fi
    # The iCloud change tokens are in the settings and match the copied database, so the new
    # app carries on syncing from where NetNewsList Dev was.
    REL_PREFS="$REL_DATA/Library/Preferences/$BUNDLE_ID"
    defaults delete "$REL_PREFS" >/dev/null 2>&1 || true
    defaults export "$DEV_DATA/Library/Preferences/$DEV_BUNDLE_ID" - | defaults import "$REL_PREFS" -
    # Pages shared to NetNewsList Dev that it hasn't saved yet.
    DEV_INBOX="$HOME/Library/Group Containers/P4RDBS9676.$DEV_BUNDLE_ID/Inbox"
    if [ -d "$DEV_INBOX" ] && [ -n "$(ls -A "$DEV_INBOX")" ]; then
        mkdir -p "$HOME/Library/Group Containers/P4RDBS9676.$BUNDLE_ID/Inbox"
        cp -p "$DEV_INBOX"/* "$HOME/Library/Group Containers/P4RDBS9676.$BUNDLE_ID/Inbox/"
    fi

    DEV_COUNTS=$(list_counts "$DEV_DATA")
    REL_COUNTS=$(list_counts "$REL_DATA")
    [ "$DEV_COUNTS" = "$REL_COUNTS" ] ||
        fail "The copy doesn't match: NetNewsList Dev has $DEV_COUNTS, NetNewsList has $REL_COUNTS."
    rm "$PORT_PENDING"
    echo "▸ Copied: $REL_COUNTS"
fi

open "$DEST"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")
echo "✓ NetNewsList $VERSION ($(git rev-parse --short HEAD)) is running from $DEST"
