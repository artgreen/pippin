"""serial_send.py -- blast a file over serial to the Apple receiver.

Wire protocol:
  Mac -> Apple:  A5 5A  LL LH  CL CH  <payload bytes>     (request)
  Apple -> Mac:  ST                                       (1-byte response)
Checksum: 16-bit additive sum of payload, little-endian on the wire.

The response is a single status byte: 0 = OK, nonzero = failure reason
(1 = checksum mismatch, 2 = timeout, 3 = bad length -- see src/recv_body.s).
The receiver already validated the checksum against the header, so a 0 ack is
authoritative; there's no count/checksum echo to cross-check (it isn't needed).
"""

import sys
import time

try:
    from transport import TcpTransport, SerialTransport
except ImportError:
    from tools.transport import TcpTransport, SerialTransport

SYNC = b"\xA5\x5A"

# status byte -> human-readable reason (mirrors src/recv_body.s STAT_*)
STATUS_NAMES = {0: "OK", 1: "checksum mismatch", 2: "timeout", 3: "bad length"}


def checksum16(data: bytes) -> int:
    """16-bit additive checksum: (sum of all bytes) mod 65536."""
    total = 0
    for b in data:
        total = (total + b) & 0xFFFF
    return total


def build_header(length: int, cksum: int) -> bytes:
    """Build the transfer header: SYNC + length(LE16) + checksum(LE16)."""
    if not (0 <= length <= 0xFFFF):
        raise ValueError(f"length {length} out of 16-bit range")
    if not (0 <= cksum <= 0xFFFF):
        raise ValueError(f"checksum {cksum} out of 16-bit range")
    return SYNC + bytes([
        length & 0xFF, (length >> 8) & 0xFF,
        cksum & 0xFF, (cksum >> 8) & 0xFF,
    ])


def read_ack(transport, total_timeout: float = 10.0):
    """Read the Apple's 1-byte status ack (0=OK, nonzero=failure reason).

    The receiver transmits nothing until it has finished, so the first byte
    back is the ack -- no sync hunt needed. Returns (status_or_None, raw)."""
    raw = b""
    deadline = time.monotonic() + total_timeout
    while time.monotonic() < deadline:
        chunk = transport.read_chunk(16, timeout=0.5)
        if chunk:
            raw += chunk
            return raw[0], raw
    return None, raw


def send_file(transport, data: bytes, byte_delay: float = 0.0,
              result_timeout: float = 10.0) -> dict:
    """Send header + payload, read the 1-byte status ack, return a verdict."""
    cksum = checksum16(data)
    transport.write(build_header(len(data), cksum))
    if byte_delay > 0:
        for b in data:
            transport.write(bytes([b]))
            time.sleep(byte_delay)
    else:
        transport.write(data)

    status, raw = read_ack(transport, total_timeout=result_timeout)
    if status is None:
        return {"ok": False, "sent_len": len(data), "sent_cksum": cksum,
                "status": None, "raw": raw.hex(),
                "error": f"no ack byte received within {result_timeout:g}s"}
    return {"ok": status == 0, "sent_len": len(data), "sent_cksum": cksum,
            "status": status, "raw": raw.hex(), "error": None}


def main(argv=None) -> int:
    import argparse
    p = argparse.ArgumentParser(description="Send a file to the Apple receiver over serial.")
    p.add_argument("file", help="path to the file to send")
    p.add_argument("--transport", choices=["tcp", "serial"], default="tcp",
                   help="tcp = bridge/emulator (default); serial = direct device")
    p.add_argument("--host", default="localhost", help="TCP host (tcp transport)")
    p.add_argument("--port", type=int, default=1977, help="TCP port (tcp transport)")
    p.add_argument("--device", default=None,
                   help="serial device (serial transport); auto-detects /dev/cu.PL2303* if omitted")
    p.add_argument("--baud", type=int, default=9600,
                   help="line speed for serial transport (Apple is fixed at 9600; "
                        "mismatch deliberately for troubleshooting)")
    p.add_argument("--byte-delay", type=float, default=0.0,
                   help="seconds to sleep between payload bytes (throttle for diagnosis; "
                        "must stay under the receiver's ~2-8s per-byte timeout)")
    args = p.parse_args(argv)

    with open(args.file, "rb") as f:
        data = f.read()

    if args.transport == "tcp":
        t = TcpTransport(args.host, args.port)
    else:
        device = args.device
        if device is None:
            import glob
            matches = sorted(glob.glob("/dev/cu.PL2303*") + glob.glob("/dev/cu.usbserial-*"))
            if not matches:
                print("ERROR: no /dev/cu.PL2303* or /dev/cu.usbserial-* found", file=sys.stderr)
                return 2
            device = matches[0]
        t = SerialTransport(device, args.baud)

    try:
        print(f">> sending {len(data)} bytes (cksum=${checksum16(data):04X}) via {args.transport}")
        v = send_file(t, data, byte_delay=args.byte_delay)
    finally:
        t.close()

    if v["error"]:
        print(f"<< FAIL: {v['error']}")
        return 1
    st = v["status"]
    name = STATUS_NAMES.get(st, f"unknown (${st:02X})")
    print(f"<< apple: status={st} ({name})")
    print(f"   sent:  {v['sent_len']} bytes cksum=${v['sent_cksum']:04X}")
    if v["ok"]:
        print("   VERDICT: PASS")
        return 0
    print(f"   VERDICT: FAIL ({name})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
