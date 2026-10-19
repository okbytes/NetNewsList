#!/bin/bash
# Unregister the stray copies of the Mac app that macOS still lists, so the Services menu shows one
# Save to NetNewsList and netnewslist:// links reach the installed app.
# Usage: scripts/unregister-stale-builds.sh [--dry-run]
#
# xcodebuild registers every Mac app it builds with LaunchServices and unregisters it only on
# Product › Clean Build Folder, so a build an agent leaves in a scratchpad stays registered. Each
# copy adds its own item to the Services menu (Save to NetNewsList, or Save to NetNewsList Dev),
# and once more than three services apply, a right-click menu moves them all into a Services
# submenu. This unregisters every copy of the Mac app (eitherslice.NetNewsList, its -DEBUG build
# NetNewsList Dev, and the work build, .Web) except NetNewsList.app in ~/Applications or
# /Applications and Xcode's own builds in ~/Library/Developer/Xcode/DerivedData, then refreshes
# the Services list. Files stay where they are; a copy registers again when it's built or opened.
# --dry-run lists the copies without unregistering them.
set -euo pipefail

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE_IDS="eitherslice.NetNewsList eitherslice.NetNewsList-DEBUG eitherslice.NetNewsList.Web"

fail() {
    echo "✗ $1" >&2
    exit 1
}

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "Unknown option $arg. Usage: scripts/unregister-stale-builds.sh [--dry-run]" ;;
    esac
done

# Prints the path of every registered app with one of BUNDLE_IDS, one per line.
registered_copies() {
    "$LSREGISTER" -dump 2>/dev/null | awk -v ids="$BUNDLE_IDS" '
        BEGIN { n = split(ids, list, " "); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
        function emit() { if (bundle && path != "" && (id in wanted)) print path }
        /^-+$/ { emit(); bundle = 0; path = ""; id = ""; next }
        /^bundle id:/ { bundle = 1 }
        bundle && /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
        bundle && /^identifier:/ { id = $2 }
        END { emit() }
    ' | sort -u
}

keep() {
    case "$1" in
        "$HOME/Applications/NetNewsList.app" | /Applications/NetNewsList.app | "$HOME/Library/Developer/Xcode/DerivedData/"*) return 0 ;;
        *) return 1 ;;
    esac
}

STALE=()
while IFS= read -r app; do
    keep "$app" || STALE+=("$app")
done < <(registered_copies)

if [ ${#STALE[@]} -eq 0 ]; then
    echo "✓ No stray copies of NetNewsList are registered."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Would unregister ${#STALE[@]}:"
    printf '  %s\n' "${STALE[@]}"
    exit 0
fi

for app in "${STALE[@]}"; do
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    echo "▸ Unregistered $app"
done
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

LEFT=0
while IFS= read -r app; do
    keep "$app" || LEFT=$((LEFT + 1))
done < <(registered_copies)
[ "$LEFT" -eq 0 ] || fail "$LEFT still registered; run this again, or log out and back in."
echo "✓ Unregistered ${#STALE[@]}. Quit and reopen the app you right-click in to see the new Services list."
