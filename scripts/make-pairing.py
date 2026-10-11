#!/usr/bin/env python3
"""Export this Mac's lockdown pairing record for a connected iPhone, for import into the app.

Reads the record usbmuxd already holds (the one Xcode/Finder created when you tapped "Trust"), so no root
and no new pairing are needed. Writes <UDID>.mobiledevicepairing; AirDrop it to the phone and import it in
the app's Setup screen.

    scripts/make-pairing.py            # first USB-connected device
    scripts/make-pairing.py <UDID>     # a specific device
"""

import os
import plistlib
import socket
import struct
import sys

SOCKET = "/var/run/usbmuxd"


def request(payload: dict) -> dict:
    body = plistlib.dumps({"ClientVersionString": "fingertip", "ProgName": "make-pairing", **payload})
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCKET)
        # usbmuxd header: total length, version 1, message 8 (plist), tag.
        s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)
        header = recv_exactly(s, 16)
        length = struct.unpack("<IIII", header)[0]
        return plistlib.loads(recv_exactly(s, length - 16))


def recv_exactly(s: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise SystemExit("usbmuxd closed the connection")
        data += chunk
    return data


def main() -> None:
    udid = sys.argv[1] if len(sys.argv) > 1 else None
    if udid is None:
        devices = request({"MessageType": "ListDevices"}).get("DeviceList", [])
        usb = [d["Properties"] for d in devices if d["Properties"].get("ConnectionType") == "USB"]
        if not usb:
            raise SystemExit("No USB-connected device. Plug in the iPhone and tap Trust.")
        udid = usb[0]["SerialNumber"]

    reply = request({"MessageType": "ReadPairRecord", "PairRecordID": udid})
    data = reply.get("PairRecordData")
    if not data:
        raise SystemExit(f"No pair record for {udid} (usbmuxd said: {reply}). Open Finder/Xcode with the phone plugged in and tap Trust.")

    record = plistlib.loads(data)
    missing = [k for k in ("HostCertificate", "HostPrivateKey", "RootCertificate", "DeviceCertificate", "HostID") if k not in record]
    if missing:
        raise SystemExit(f"Pair record is missing {missing}")
    record["UDID"] = udid  # jitterbug/StikDebug convention

    out = f"{udid}.mobiledevicepairing"
    with open(out, "wb") as f:
        plistlib.dump(record, f)
    os.chmod(out, 0o600)
    print(f"Wrote {out} (HostID {record['HostID']}). AirDrop it to the iPhone and import it in Setup.")
    print("It grants full device access over the network: keep it private and delete it after importing.")


if __name__ == "__main__":
    main()
