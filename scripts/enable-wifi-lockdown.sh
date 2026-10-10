#!/bin/bash
# Lets lockdownd accept network connections from the pairing record (needed for the LocalDevVPN loopback;
# without it connections to 10.7.0.1:62078 are reset). Same as StikDebug/jitterbug pairing. Run over USB once.
set -euo pipefail
cd "$(dirname "$0")/../vendor/TouchSynthesis/vendor/idevice"
SRC=tools/src/lockdown.rs
# The stock `lockdown set` only writes strings; this key must be a boolean. Patch, build, restore.
cp "$SRC" "$SRC.orig"
trap 'mv "$SRC.orig" "$SRC"' EXIT
sed -i '' 's/let value = Value::String(value_str.clone());/let value = match value_str.as_str() { "true" => Value::Boolean(true), "false" => Value::Boolean(false), _ => Value::String(value_str.clone()) };/' "$SRC"
PATH="$HOME/.cargo/bin:$PATH" cargo build -q --release --bin idevice-tools
T=target/release/idevice-tools
$T lockdown --domain com.apple.mobile.wireless_lockdown set true EnableWifiConnections
$T lockdown --domain com.apple.mobile.wireless_lockdown get | grep EnableWifiConnections
