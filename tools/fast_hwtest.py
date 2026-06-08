"""fast_hwtest.py -- one-shot acceptance test for PIP on real hardware.

Opens ONE TCP connection to the bridge (:1977) and drives the binary protocol:
PING gate -> STATUS -> READ -> WRITE+readback -> SENDKEY -> adversarial frames
-> latency. Single connection on purpose (survives a no-fork socat). Bails
cleanly if the PING gate fails (e.g. wrong build installed).

    uv run --with mcp tools/fast_hwtest.py            # tcp :1977
    uv run --with mcp tools/fast_hwtest.py --port 1977
"""
import argparse
import statistics
import sys
import time

sys.path.insert(0, "tools")
from transport import TcpTransport, SerialTransport          # noqa: E402
from pippin_mcp import PippinClient, _read_response_frame     # noqa: E402
from pippin_protocol import (                                 # noqa: E402
    encode_request, decode_response,
    OP_READ, ST_OK, ST_BAD_CK, ST_BAD_OP, ST_FORBIDDEN, ST_BAD_LEN,
)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--transport", choices=["tcp", "serial"], default="tcp")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--device", default=None)
    p.add_argument("--baud", type=int, default=9600)
    p.add_argument("--skip-sendkey", action="store_true",
                   help="don't inject a keystroke into the live prompt")
    args = p.parse_args(argv)

    if args.transport == "tcp":
        t = TcpTransport(args.host, args.port)
    else:
        if not args.device:
            p.error("--transport serial requires --device (e.g. /dev/cu.usbserial-XXXX)")
        t = SerialTransport(args.device, args.baud)
    c = PippinClient(t)

    def raw(frame, label, expect_st):
        t.write(frame)
        try:
            rb = _read_response_frame(t)
            st, res = decode_response(rb)
            ok = "OK" if st == expect_st else f"!! expected ST={expect_st}"
            print(f"  {label:38} -> ST={st} res={res.hex() or '-':12} [{rb.hex()}] {ok}")
        except Exception as e:
            print(f"  {label:38} -> ERROR {e!r}")

    print("== PING gate ==")
    t0 = time.monotonic()
    try:
        ok = c.ping()
    except Exception as e:
        print(f"  PING failed: {e!r}")
        print("  No binary reply. Is PIP (binary build) the installed binary,")
        print("  and is the comfort '@' showing top-right? Stopping before the battery.")
        t.close()
        return 1
    print(f"  ping -> {'OK' if ok else 'NON-OK'}  ({(time.monotonic()-t0)*1000:.0f} ms)")
    if not ok:
        t.close()
        return 1

    print("== STATUS ==")
    print("  " + c.status())

    print("== READ ==")
    print(f"  $0400 x16 (top text row): {c.read_memory(0x0400, 16)}")

    print("== WRITE + readback ($0300 = ca fe 42) ==")
    c.write_memory(0x0300, "cafe42")
    back = c.read_memory(0x0300, 3)
    print(f"  readback: {back}  {'OK' if back == 'cafe42' else '!! MISMATCH'}")

    if not args.skip_sendkey:
        print("== SENDKEY 'A' (watch the ] prompt -- an 'A' should appear) ==")
        print("  " + c.send_keystroke(65))

    print("== Adversarial (each must return its ST, no hang) ==")
    raw(bytes([0xA5, 0x01, 0x00, 0xFF]),                 "bad checksum",       ST_BAD_CK)
    raw(bytes([0xA5, 0x7F, 0x00, 0x7F]),                 "bad opcode",         ST_BAD_OP)
    raw(encode_request(OP_READ, bytes([0x00, 0xC0, 0x10])), "forbidden read $C000", ST_FORBIDDEN)
    raw(bytes([0xA5, 0x04, 0x02, 0x0D, 0x00, 0x13]),     "sendkey wrong ALEN", ST_BAD_LEN)

    print("== Latency (median of 15 round-trips) ==")
    def med(fn, n=15):
        s = []
        for _ in range(n):
            a = time.monotonic(); fn(); s.append((time.monotonic() - a) * 1000)
        return statistics.median(s), min(s), max(s)
    mp = med(c.ping)
    mr = med(lambda: c.read_memory(0x0400, 16))
    print(f"  ping (8 wire bytes):    median {mp[0]:.0f} ms  (min {mp[1]:.0f} / max {mp[2]:.0f})")
    print(f"  read16 (27 wire bytes): median {mr[0]:.0f} ms  (min {mr[1]:.0f} / max {mr[2]:.0f})")

    t.close()
    print("== DONE ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
