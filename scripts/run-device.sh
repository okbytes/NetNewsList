#!/bin/bash

# Build, install, and launch the iOS app on an iPhone using the project's existing signing.
# Adapted from Verbatim's scripts/run-device.sh and scripts/lib/workflow.sh; this project has no
# other scripts that would share the library, so the parts it needs live here.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PROJECT="NetNewsWire.xcodeproj"
SCHEME="NetNewsWire-iOS"
LOCK_DIR="$ROOT/build/xcodebuild.lock"
LOCK_OWNED=0
CHILD_PID=
RUN_DIR=
RUN_STARTED=$SECONDS

usage() {
    printf '%s\n' \
        'Usage: scripts/run-device.sh [iPhone UDID] [--no-build] [--console]' \
        'Connect and unlock your paired iPhone; a single available iPhone is selected automatically.' \
        'With multiple iPhones, pass an Identifier from: xcrun devicectl list devices' \
        'Uses existing Xcode signing; installs in place without deleting app data. A build for a device' \
        'registers it with the team and adds it to the development profile. Rerun it once a year, after' \
        'a new Apple Development certificate, so the app on the phone keeps launching.' \
        'The app syncs with your real iCloud data (the Development environment).' \
        '--no-build installs the existing Debug binary; source edits are not compiled.' \
        '--console stays attached until the app exits; stop it to terminate the app.'
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

release_build_lock() {
    if [ "$LOCK_OWNED" -eq 1 ] && [ -f "$LOCK_DIR/pid" ] && [ "$(<"$LOCK_DIR/pid")" = "$$" ]; then
        rm "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR"
        LOCK_OWNED=0
    fi
}

cleanup_workflow() {
    local status=$?
    # A second signal mustn't cut cleanup short and leave the build lock behind.
    trap - EXIT
    trap '' INT TERM HUP
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    release_build_lock
    if [ -n "$RUN_DIR" ]; then
        printf 'Exit status: %s\nElapsed: %ss\nLogs: %s\n' "$status" "$((SECONDS - RUN_STARTED))" "$RUN_DIR" | tee "$RUN_DIR/summary.txt"
    fi
    exit "$status"
}

start_workflow() {
    mkdir -p "$ROOT/build/logs"
    # Keep two weeks of runs. Another run may be pruning the same folder, so ignore races.
    find "$ROOT/build/logs" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true
    RUN_DIR=$(mktemp -d "$ROOT/build/logs/$(date +%Y%m%d-%H%M%S)-$1.XXXXXX")
    trap cleanup_workflow EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf 'Logs: %s\n' "$RUN_DIR"
}

acquire_build_lock() {
    local owner invalid_owner_waited=0 announced=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [ ! -d "$LOCK_DIR" ]; then
            [ ! -e "$LOCK_DIR" ] || fail "Build lock path is not a directory: $LOCK_DIR"
            [ -w "$(dirname "$LOCK_DIR")" ] || fail "Cannot create build lock: $LOCK_DIR"
            continue
        fi
        owner=$( { read -r owner < "$LOCK_DIR/pid" && printf '%s' "$owner"; } 2>/dev/null || true)
        [ -d "$LOCK_DIR" ] || continue
        case "$owner" in
            ''|*[!0-9]*)
                if [ "$invalid_owner_waited" -ge 5 ]; then
                    fail "Build lock has no valid owner: $LOCK_DIR. Inspect running builds before manually removing it."
                fi
                invalid_owner_waited=$((invalid_owner_waited + 1))
                ;;
            *)
                if ! kill -0 "$owner" 2>/dev/null; then
                    [ -d "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ] || continue
                    fail "Build lock belongs to stopped PID $owner: $LOCK_DIR. Check for orphaned xcodebuild processes before manually removing it."
                fi
                invalid_owner_waited=0
                ;;
        esac
        if [ "$announced" -eq 0 ]; then
            printf 'Waiting for build lock: %s (PID %s)\n' "$LOCK_DIR" "${owner:-pending}"
            announced=1
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_OWNED=1
}

run_logged() {
    local name=$1 status started=$SECONDS
    shift
    LAST_LOG="$RUN_DIR/$name.log"
    printf '%q ' "$@" >> "$RUN_DIR/commands.txt"
    printf '\n' >> "$RUN_DIR/commands.txt"
    printf '%s…\n' "$name"
    "$@" > "$LAST_LOG" 2>&1 &
    CHILD_PID=$!
    if wait "$CHILD_PID"; then
        status=0
    else
        status=$?
    fi
    CHILD_PID=
    printf '%s: status %s (%ss) — %s\n' "$name" "$status" "$((SECONDS - started))" "$LAST_LOG" | tee -a "$RUN_DIR/steps.txt"
    if [ "$status" -ne 0 ]; then
        if ! grep -E 'error:|warning:|failed|Failed|FAIL|✘' "$LAST_LOG" | head -30; then
            tail -30 "$LAST_LOG"
        fi
    fi
    return "$status"
}

resolve_device() {
    DEVICE=${1:-}
    [ -z "$DEVICE" ] || return 0
    run_logged devices xcrun devicectl list devices --timeout 15 \
        --filter "properties.hardware.reality = 'physical' AND properties.hardware.deviceType = 'iPhone' AND (State = 'connected' OR State BEGINSWITH 'available')" \
        --hide-default-columns --columns properties.hardware.udid --hide-headers
    local device_ids device_count
    device_ids=$(awk '/^[[:space:]]*[[:xdigit:]-]+[[:space:]]*$/ { print $1 }' "$LAST_LOG")
    device_count=$(printf '%s\n' "$device_ids" | awk 'NF { count++ } END { print count+0 }')
    [ "$device_count" -eq 1 ] || fail "Found $device_count available physical iPhones. Connect and unlock one phone or specify its UDID. Device list: $LAST_LOG"
    DEVICE=$device_ids
}

build_app() {
    printf 'Result bundle: %s\n' "$RUN_DIR/Build.xcresult"
    run_logged build xcodebuild build \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination "$DESTINATION" -resultBundlePath "$RUN_DIR/Build.xcresult" "$@"
}

read_app_settings() {
    run_logged build-settings xcodebuild -showBuildSettings \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination "$DESTINATION"
    TARGET_BUILD_DIR=$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' "$LAST_LOG")
    WRAPPER_NAME=$(awk -F ' = ' '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }' "$LAST_LOG")
    BUNDLE_ID=$(awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }' "$LAST_LOG")
    if [ -z "$TARGET_BUILD_DIR" ] || [ -z "$WRAPPER_NAME" ] || [ -z "$BUNDLE_ID" ]; then
        fail "Could not locate the built app or bundle identifier. Build settings: $LAST_LOG"
    fi
    APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
    [ -d "$APP_PATH" ] || fail "Built app not found: $APP_PATH. Build settings: $LAST_LOG"
}

REQUESTED_DEVICE=
SKIP_BUILD=0
CONSOLE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --no-build) SKIP_BUILD=1; shift ;;
        --console) CONSOLE=1; shift ;;
        -*) usage >&2; fail "Unknown argument: $1" ;;
        *)
            [ -z "$REQUESTED_DEVICE" ] && [ -n "$1" ] || fail 'Specify one nonempty iPhone UDID.'
            REQUESTED_DEVICE=$1
            shift
            ;;
    esac
done

start_workflow device
acquire_build_lock
resolve_device "$REQUESTED_DEVICE"
DESTINATION="platform=iOS,id=$DEVICE"
printf 'Destination: %s\n' "$DESTINATION"
if [ "$SKIP_BUILD" -eq 0 ]; then
    build_app -allowProvisioningUpdates -allowProvisioningDeviceRegistration
else
    printf 'Using existing Debug binary; source edits are not compiled.\n'
fi
read_app_settings
run_logged install xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"
if [ "$CONSOLE" -eq 1 ]; then
    release_build_lock
    xcrun devicectl device process launch --console --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
else
    run_logged launch xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
fi
