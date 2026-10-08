#!/bin/bash
[ -n "${XCODE_LOCK_HELD:-}" ] || ! command -v xcode-lock >/dev/null || exec xcode-lock "$0" "$@"

# Rebuilds the signed iOS app and reinstalls it on the iPhone without launching it, so it carries
# the current signing certificate and a fresh profile. renew-apps (~/.local/bin, from chezmoi) runs
# this once a year, after a new Apple Development certificate. It builds into the default
# DerivedData, as Xcode does, which is where renew-apps checks the result.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=$(xcrun devicectl list devices --timeout 15 \
    --filter "properties.hardware.reality = 'physical' AND properties.hardware.deviceType = 'iPhone' AND (State = 'connected' OR State BEGINSWITH 'available')" \
    --hide-default-columns --columns properties.hardware.udid --hide-headers |
    awk '/^[[:space:]]*[[:xdigit:]-]+[[:space:]]*$/ { print $1 }')
if [ "$(printf '%s' "$DEVICE" | grep -c .)" -ne 1 ]; then
    printf 'Connect and unlock exactly one iPhone. Found: %s\n' "${DEVICE:-none}" >&2
    exit 1
fi

SETTINGS=(-project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -configuration Debug -destination "platform=iOS,id=$DEVICE")
xcodebuild build -quiet "${SETTINGS[@]}" -allowProvisioningUpdates -allowProvisioningDeviceRegistration
APP=$(xcodebuild -showBuildSettings -json "${SETTINGS[@]}" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
settings = next(entry["buildSettings"] for entry in json.load(sys.stdin) if entry["target"] == "NetNewsWire-iOS")
print(settings["TARGET_BUILD_DIR"] + "/" + settings["WRAPPER_NAME"])')
xcrun devicectl device install app --device "$DEVICE" "$APP"
