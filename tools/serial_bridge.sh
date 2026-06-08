#!/usr/bin/env bash
# serial_bridge.sh -- expose a USB-serial dongle as a TCP socket on :1977.
#
# The host tools talk to the Apple's Super Serial Card over TCP :1977 (that is
# what microM8 and AppleWin present an emulated SSC as). To drive REAL Apple II
# hardware instead, this bridges that same TCP port to a USB-serial null-modem
# dongle with socat, so TcpTransport (pippin_mcp.py) and serial_send.py work
# unchanged whether the other end is an emulator or a physical machine.
#
# Not machine-specific: any Apple II reached over a serial dongle (//e, //c,
# //c+, IIgs, ...). tincan.py is a self-contained Python equivalent.
#
# Usage: tools/serial_bridge.sh [device] [port]
#   device defaults to the first /dev/cu.PL2303* or /dev/cu.usbserial-*
#   port   defaults to 1977
set -euo pipefail

DEV="${1:-$(ls /dev/cu.PL2303* /dev/cu.usbserial-* 2>/dev/null | head -1 || true)}"
PORT="${2:-1977}"

if [ -z "$DEV" ]; then
  echo "no serial device found; pass one explicitly: tools/serial_bridge.sh /dev/cu.XXXX" >&2
  exit 1
fi
if ! command -v socat >/dev/null 2>&1; then
  echo "socat not installed (brew install socat)" >&2
  exit 1
fi

echo "bridging TCP :$PORT <-> $DEV (9600 8N1, raw)"
# ispeed/ospeed (not b9600) is the option set that works on a real //c+ over a
# USB-serial dongle. ,fork is load-bearing: without
# it socat exits when the first client disconnects, and the next connect gets
# "Connection refused".
# bind=127.0.0.1 keeps the listener on localhost: the bridge has no auth, so
# binding all interfaces would let anyone on the network read/write the Apple's
# memory and inject keystrokes.
exec socat -d TCP-LISTEN:"$PORT",bind=127.0.0.1,reuseaddr,fork \
  "$DEV",ispeed=9600,ospeed=9600,raw,echo=0,crtscts=0,clocal=1,cs8,parenb=0,cstopb=0
