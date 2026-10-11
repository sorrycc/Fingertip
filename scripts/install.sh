#!/bin/bash
# Build, install, and (optionally) push the pairing record into the app's Documents folder.
#
#   scripts/install.sh               # first connected device
#   scripts/install.sh <UDID>        # a specific device
#   PUSH_PAIRING=0 scripts/install.sh  # skip the pairing record
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=com.sorrycc.fingertip
UDID="${1:-$(xcrun devicectl list devices --hide-default-columns --columns Identifier --hide-headers 2>/dev/null | head -1 | tr -d ' ')}"
[ -n "$UDID" ] || { echo "No device found (xcrun devicectl list devices)"; exit 1; }
HW_UDID="$(xcrun devicectl device info details --device "$UDID" 2>/dev/null | awk '/ udid:/ {print $NF; exit}')"

[ -f build/idevice/libidevice_ffi.a ] && [ -x build/idevice/idevice-tools ] || scripts/build-idevice.sh
[ -f Config/Secrets.xcconfig ] || cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig

xcodegen generate --quiet
xcodebuild -project Fingertip.xcodeproj -scheme Fingertip -configuration Debug \
  -destination "id=${HW_UDID:-$UDID}" -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  > build/xcodebuild.log 2>&1 || { grep -E 'error:' build/xcodebuild.log | sort -u; echo "Build failed (full log: build/xcodebuild.log)"; exit 1; }

APP=build/DerivedData/Build/Products/Debug-iphoneos/Fingertip.app
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP"

if [ "${PUSH_PAIRING:-1}" = 1 ]; then
  push() {
    xcrun devicectl device copy to --device "$UDID" --source "$1" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --destination "Documents/$2" >/dev/null
    echo "Installed $2 into the app."
  }
  mkdir -p build/pairing
  # Classic lockdown record (exported from usbmuxd; no new pairing).
  (cd build/pairing && python3 ../../scripts/make-pairing.py ${HW_UDID:+"$HW_UDID"} >/dev/null)
  push "$(ls -t build/pairing/*.mobiledevicepairing | head -1)" pairing.plist
  # RemotePairing file for iOS 26.4+ (the tunnel the app actually uses). Created once over USB.
  [ -f build/pairing/rp_pairing.plist ] || build/idevice/idevice-tools rppairing pair fingertip build/pairing/rp_pairing.plist
  chmod 600 build/pairing/rp_pairing.plist
  push build/pairing/rp_pairing.plist rp_pairing.plist
fi
echo "Done. Open 'Agent' on the phone → Setup → Start UI automation."
