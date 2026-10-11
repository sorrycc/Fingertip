#!/bin/bash
# Fetch the app's automation log from the phone (works even when the devicectl console stream has dropped).
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-$(xcrun devicectl list devices --hide-default-columns --columns Identifier --hide-headers 2>/dev/null | head -1 | tr -d ' ')}"
mkdir -p build
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier com.sorrycc.fingertip --source Documents/automation.log --destination build/automation.log >/dev/null
cat build/automation.log
