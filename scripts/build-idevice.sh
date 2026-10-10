#!/bin/bash
# Builds libidevice_ffi.a for iOS from vendor/idevice (upstream, with RemotePairing support for iOS 26.4+)
# plus TouchSynthesis's readwrite_send/recv FFI patch, and the macOS idevice-tools used for pairing.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
OUT=build/idevice
mkdir -p "$OUT"
rustup target list --installed | grep -q aarch64-apple-ios || rustup target add aarch64-apple-ios

(cd vendor/idevice && { git apply --check ../TouchSynthesis/scripts/readwrite-ffi.patch 2>/dev/null && git apply ../TouchSynthesis/scripts/readwrite-ffi.patch || echo "readwrite patch already applied"; })

FEATURES="full,ring"
(cd vendor/idevice/ffi && cargo build --release --target aarch64-apple-ios --no-default-features --features "$FEATURES")
cp vendor/idevice/target/aarch64-apple-ios/release/libidevice_ffi.a "$OUT/"
cp vendor/idevice/ffi/idevice.h vendor/idevice/ffi/plist.h "$OUT/" 2>/dev/null || cp vendor/idevice/ffi/idevice.h "$OUT/"

if [ "${SKIP_TOOLS:-0}" != 1 ]; then
  (cd vendor/idevice && cargo build --release --bin idevice-tools)
  cp vendor/idevice/target/release/idevice-tools "$OUT/"
fi
ls -la "$OUT"
