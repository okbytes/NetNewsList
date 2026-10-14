#!/bin/bash
# Build the work-computer copy of NetNewsList: the full Mac app, Developer ID-signed and without
# the iCloud and push entitlements, for a managed Mac where IT blocks signing macOS in to iCloud.
# Usage: scripts/build-work-mac.sh [--no-notarize]
#
# The CloudKit framework only ever uses the Mac's own iCloud account, so this build syncs over
# CloudKit Web Services with an Apple ID sign-in inside the app (choose NetNewsList › Sign In to
# iCloud…). Without the iCloud entitlement it needs no provisioning profile, so it runs on a Mac
# that isn't registered with the team. xcconfig/NetNewsList_work.xcconfig holds the differences:
# bundle IDs eitherslice.NetNewsList.Web and .Web.ShareExtension, its own app group, the
# entitlements and the signing; the name (NetNewsList) and link scheme (netnewslist://) are the
# everyday app's.
#
# The CloudKit Web Services API token and environment come from NETNEWSLIST_CLOUDKIT_API_TOKEN and
# NETNEWSLIST_CLOUDKIT_ENVIRONMENT, else from the git-ignored local-config.json at the
# repository's root (apiToken, environment). Without a token the app asks for one at sign-in. A token is built into the app's Info.plist, so keep the zip to yourself.
#
# It notarizes when the notarytool keychain profile NOTARY_PROFILE (default netnewslist-notary)
# exists; the script prints the one-time command that creates it. Without one, or with
# --no-notarize, the app is signed but not notarized, and Gatekeeper on the work Mac blocks it.
# Output: build/Work.noindex/NetNewsList-Work.zip, the copy to install, and the app it holds.
#
# xcodebuild registers every app it builds with LaunchServices, and this one claims netnewslist://,
# which on this Mac must keep opening ~/Applications/NetNewsList.app (scripts/install-mac.sh). The script unregisters every copy under build/ when it ends, even after
# a failure, and checks where netnewslist:// links go. Never open build/Work.noindex/NetNewsList.app here.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="build/Work.noindex"
DERIVED="build/WorkDerivedData.noindex"
ARCHIVE="$WORK/NetNewsList.xcarchive"
APP="$WORK/NetNewsList.app"
ZIP="$WORK/NetNewsList-Work.zip"
NOTARY_ZIP="$WORK/NetNewsList-notarize.zip"
APP_ENTITLEMENTS="$WORK/NetNewsList-entitlements.plist"
# Holds the token for one xcodebuild run, so it isn't on the command line, where the process list
# and xcodebuild's own output would show it (-quiet keeps xcodebuild from printing this file's
# settings). Like every build setting, it still lands in the build log under $DERIVED/Logs.
SETTINGS="$WORK/Settings.xcconfig"
CONFIG="local-config.json"
TEAM_ID="P4RDBS9676"
NOTARY_PROFILE="${NOTARY_PROFILE:-netnewslist-notary}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() {
    echo "✗ $1" >&2
    exit 1
}

warn() {
    echo "! $1" >&2
}

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "Unknown option $arg. Usage: scripts/build-work-mac.sh [--no-notarize]" ;;
    esac
done

unregister_builds() {
    local dir app
    for dir in "$WORK" "$DERIVED"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' app; do
            "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
        done < <(find "$dir" -name '*.app' \( -type d -o -type l \) -prune -print0 2>/dev/null)
    done
}

cleanup() {
    local status=$?
    trap - EXIT
    rm -f "$SETTINGS" "$NOTARY_ZIP" "$APP_ENTITLEMENTS"
    unregister_builds
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The apps that answer netnewslist:// links on this Mac, the default first.
link_handlers() {
    osascript -l JavaScript -e '
        ObjC.import("AppKit");
        const link = $.NSURL.URLWithString("netnewslist://add");
        const workspace = $.NSWorkspace.sharedWorkspace;
        const preferred = workspace.URLForApplicationToOpenURL(link);
        const all = workspace.URLsForApplicationsToOpenURL(link);
        const paths = [preferred.isNil() ? "(none)" : preferred.path.js];
        for (let i = 0; i < all.count; i++) paths.push(all.objectAtIndex(i).path.js);
        paths.join("\n");'
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

config_value() {
    [ -f "$CONFIG" ] || return 0
    plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null || true
}

# Checks one signed bundle: Developer ID from this team and a secure timestamp, plus the hardened
# runtime when the second argument is "executable". Notarization requires all three.
check_signature() {
    local details authority
    details=$(codesign -dvv "$1" 2>&1) || fail "$1 isn't signed."
    authority=$(sed -n 's/^Authority=//p' <<<"$details" | head -1)
    [[ "$authority" == "Developer ID Application: "*"($TEAM_ID)" ]] ||
        fail "$1 is signed by \"$authority\", not Developer ID Application for team $TEAM_ID."
    grep -q '^Timestamp=' <<<"$details" || fail "$1 has no secure timestamp."
    [ "${2:-}" != "executable" ] || grep -q '^CodeDirectory .*flags=.*runtime' <<<"$details" ||
        fail "$1 doesn't have the hardened runtime."
}

# Prints the entitlements of a signed bundle as XML.
entitlements_of() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null
}

# The token and environment the app reads from Info.plist.
TOKEN="${NETNEWSLIST_CLOUDKIT_API_TOKEN:-}"
TOKEN_SOURCE="NETNEWSLIST_CLOUDKIT_API_TOKEN"
if [ -z "$TOKEN" ]; then
    TOKEN=$(config_value apiToken)
    TOKEN_SOURCE=$CONFIG
fi
ENVIRONMENT="${NETNEWSLIST_CLOUDKIT_ENVIRONMENT:-$(config_value environment)}"
ENVIRONMENT="${ENVIRONMENT:-development}"
case "$ENVIRONMENT" in
    development | production) ;;
    *) fail "The CloudKit environment must be development or production, not \"$ENVIRONMENT\"." ;;
esac
# Also keeps the value from changing the meaning of the generated xcconfig line.
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]*$ ]] ||
    fail "The CloudKit API token from $TOKEN_SOURCE has characters an API token can't have."
if [ -n "$TOKEN" ]; then
    echo "▸ Building in the CloudKit API token from $TOKEN_SOURCE (environment: $ENVIRONMENT)."
else
    warn "No CloudKit API token (set NETNEWSLIST_CLOUDKIT_API_TOKEN or add apiToken to $CONFIG); the app will ask for one at sign-in."
fi

security find-identity -v -p codesigning | grep -q "\"Developer ID Application: .*($TEAM_ID)\"" ||
    fail "No Developer ID Application certificate for team $TEAM_ID. Create one in Xcode (Settings › Accounts › Manage Certificates)."

unregister_builds
rm -rf "$ARCHIVE" "$APP" "$ZIP" "$NOTARY_ZIP"
mkdir -p "$WORK"
(
    umask 077
    printf '%s\n' \
        "// Written by scripts/build-work-mac.sh for one build and deleted afterwards." \
        "#include \"$ROOT/xcconfig/NetNewsList_work.xcconfig\"" \
        "NETNEWSLIST_CLOUDKIT_ENVIRONMENT = $ENVIRONMENT" \
        "NETNEWSLIST_CLOUDKIT_API_TOKEN = $TOKEN" >"$SETTINGS"
)

echo "▸ Archiving NetNewsList for the work computer (Release, Developer ID)…"
xcodebuild archive -project NetNewsWire.xcodeproj -scheme NetNewsWire -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
    -xcconfig "$SETTINGS" -quiet
rm -f "$SETTINGS"
ditto "$ARCHIVE/Products/Applications/NetNewsList.app" "$APP"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

echo "▸ Checking the signature…"
codesign --verify --deep --strict "$APP" || fail "$APP doesn't pass codesign --verify --deep --strict."
check_signature "$APP" executable
while IFS= read -r -d '' nested; do
    check_signature "$nested" "$([[ "$nested" == *.appex ]] && echo executable || true)"
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" -maxdepth 1 \( -name '*.framework' -o -name '*.appex' \) -print0)
[ ! -e "$APP/Contents/embedded.provisionprofile" ] || fail "$APP has a provisioning profile embedded."
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)

echo "▸ Checking the entitlements and Info.plist…"
EXTENSION=$(find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' | head -1)
[ -n "$EXTENSION" ] || fail "$APP has no share extension."
entitlements_of "$APP" >"$APP_ENTITLEMENTS" || fail "Can't read the entitlements of $APP."
for bundle in "$APP" "$EXTENSION"; do
    # Captured first: with pipefail, grep -q exiting at a match could fail codesign's write and
    # make the check pass.
    BUNDLE_ENTITLEMENTS=$(entitlements_of "$bundle") || fail "Can't read the entitlements of $bundle."
    if grep -q '<key>com\.apple\.developer\.' <<<"$BUNDLE_ENTITLEMENTS"; then
        fail "$bundle has com.apple.developer entitlements, which need a provisioning profile."
    fi
done
grep -q '<key>com\.apple\.security\.app-sandbox</key>' "$APP_ENTITLEMENTS" || fail "The app isn't sandboxed."
APP_GROUP=$(plist_value "$APP_ENTITLEMENTS" "com.apple.security.application-groups:0")
rm -f "$APP_ENTITLEMENTS"
INFO="$APP/Contents/Info.plist"
TRANSPORT=$(plist_value "$INFO" NetNewsListICloudTransport)
[ "$TRANSPORT" = "web" ] || fail "Info.plist NetNewsListICloudTransport is \"$TRANSPORT\", not \"web\"."
[ "$(plist_value "$INFO" CloudKitEnvironment)" = "$ENVIRONMENT" ] ||
    fail "Info.plist CloudKitEnvironment isn't $ENVIRONMENT."
[ "$(plist_value "$INFO" CloudKitAPIToken)" = "$TOKEN" ] || fail "Info.plist CloudKitAPIToken isn't the token."
[ "$(plist_value "$INFO" AppGroup)" = "$APP_GROUP" ] ||
    fail "Info.plist AppGroup doesn't match the app group entitlement ($APP_GROUP)."
APP_ID=$(plist_value "$INFO" CFBundleIdentifier)
EXTENSION_ID=$(plist_value "$EXTENSION/Contents/Info.plist" CFBundleIdentifier)
SCHEME=$(plist_value "$INFO" "CFBundleURLTypes:0:CFBundleURLSchemes:0")
VERSION=$(plist_value "$INFO" CFBundleShortVersionString)
BUILD=$(plist_value "$INFO" CFBundleVersion)
echo "  Signed by:   $AUTHORITY (hardened runtime, timestamped)"
echo "  Bundle IDs:  $APP_ID, $EXTENSION_ID"
echo "  App group:   $APP_GROUP"
echo "  Link scheme: $SCHEME://"
echo "  Sync:        $TRANSPORT (CloudKit Web Services, $ENVIRONMENT environment, token $([ -n "$TOKEN" ] && echo "built in" || echo "asked for at sign-in"))"

NOTARIZED=0
if [ "$NOTARIZE" -eq 0 ]; then
    warn "Not notarizing (--no-notarize)."
elif PROFILE_ERROR=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1 >/dev/null); then
    echo "▸ Notarizing with the \"$NOTARY_PROFILE\" profile (usually a few minutes)…"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    # Goes by the status in the output rather than notarytool's exit status, so a rejected app's
    # log is shown either way.
    RESULT=$(xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format json) || true
    rm -f "$NOTARY_ZIP"
    SUBMISSION=$(plutil -extract id raw -o - - <<<"$RESULT" 2>/dev/null || true)
    STATUS=$(plutil -extract status raw -o - - <<<"$RESULT" 2>/dev/null || true)
    if [ "$STATUS" != "Accepted" ]; then
        [ -z "$SUBMISSION" ] || xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        [ -n "$STATUS" ] || fail "notarytool couldn't notarize the app${RESULT:+: $RESULT}"
        fail "Notarization finished as \"$STATUS\" (submission ${SUBMISSION:-unknown}); the log is above."
    fi
    echo "▸ Stapling the ticket…"
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP" || fail "Gatekeeper rejects the notarized app."
    NOTARIZED=1
else
    # notarytool's own message tells a missing profile from, say, no network.
    warn "Can't notarize with the notarytool profile \"$NOTARY_PROFILE\": $(grep -m1 . <<<"$PROFILE_ERROR" || echo "notarytool failed.")"
    echo "  If the profile doesn't exist yet, create it once with:" >&2
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM_ID" >&2
    echo "  It asks for an app-specific password (account.apple.com › Sign-In and Security ›" >&2
    echo "  App-Specific Passwords). Then run this script again." >&2
fi
if [ "$NOTARIZED" -eq 0 ]; then
    warn "The app is signed but not notarized: Gatekeeper on the work Mac blocks it until it's notarized."
    echo "  Gatekeeper here says: $(spctl --assess --type execute -vv "$APP" 2>&1 | tr '\n' ' ')"
fi

echo "▸ Zipping…"
ditto -c -k --keepParent "$APP" "$ZIP"

unregister_builds
HANDLERS=$(link_handlers)
DEFAULT_HANDLER=$(head -1 <<<"$HANDLERS")
if grep -qF "$ROOT/build/" <<<"$HANDLERS"; then
    fail "LaunchServices still sends netnewslist:// to a build here: $(grep -F "$ROOT/build/" <<<"$HANDLERS" | sort -u | tr '\n' ' ')"
fi
echo "▸ netnewslist:// links on this Mac open $DEFAULT_HANDLER"

echo "✓ NetNewsList $VERSION ($BUILD, $(git rev-parse --short HEAD)) for the work computer: $ROOT/$ZIP"
echo "  $([ "$NOTARIZED" -eq 1 ] && echo "Notarized and stapled." || echo "Not notarized yet.")"
cat <<EOF
To install it on the work Mac:
  1. Copy NetNewsList-Work.zip to the work Mac and double-click it to unzip it.
  2. Drag NetNewsList.app to /Applications (or ~/Applications).
  3. Open it. The Sign In to iCloud window opens (or choose NetNewsList › Sign In to iCloud…):
     sign in with your personal Apple ID and tick Keep me signed in.
EOF
