"""bench_pip.py -- measure round-trip latency of PIP's binary protocol vs
the JSON (PIPPIN) protocol, for the success-criteria comparison ("report both").

Point it at a live endpoint (TCP :1977 bridge/emulator, or a serial device) with
the matching build installed, and pick the protocol the installed binary speaks:

    # with PIP installed:
    uv run --with mcp tools/bench_pip.py --protocol binary --op status --iters 30
    uv run --with mcp tools/bench_pip.py --protocol binary --op read --addr 1024 --len 16

    # with PIPPIN installed:
    uv run tools/bench_pip.py --protocol json --op status --iters 30
    uv run tools/bench_pip.py --protocol json --op read --addr 1024 --len 16

Reports median / min / max milliseconds. Run the same --op under each protocol
(swapping the installed binary) and compare the medians. Also prints the
resident-handler sizes for the size half of the comparison.

This is a measurement tool, not a unit test -- it needs a live Apple endpoint.
"""
import argparse
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from transport import TcpTransport, SerialTransport      # noqa: E402


def _make_transport(args):
    if args.transport == "tcp":
        return TcpTransport(args.host, args.port)
    dev = args.device
    if dev is None:
        import glob
        m = sorted(glob.glob("/dev/cu.PL2303*") + glob.glob("/dev/cu.usbserial-*"))
        if not m:
            raise SystemExit("no serial device found")
        dev = m[0]
    return SerialTransport(dev, args.baud)


def _read_json_line(transport, timeout=5.0):
    """Read a single newline-terminated JSON-RPC reply."""
    raw = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        chunk = transport.read_chunk(256, timeout=0.5)
        if chunk:
            raw += chunk
            nl = raw.find(b"\n")
            if nl != -1:
                return raw[:nl]
    raise TimeoutError(f"no JSON reply within {timeout}s (got {raw!r})")


def _json_request(op, addr, length):
    """Build a JSON-path tools/call frame for the given op (matches PIPPIN)."""
    if op == "status":
        params = {"name": "s", "arguments": {}}
    else:  # read
        params = {"name": "r", "arguments": {"a": addr, "l": length}}
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params}
    return (json.dumps(body, separators=(",", ":")) + "\n").encode()


def time_json(transport, op, addr, length, iters):
    samples = []
    for _ in range(iters):
        frame = _json_request(op, addr, length)
        t0 = time.monotonic()
        transport.write(frame)
        _read_json_line(transport)
        samples.append((time.monotonic() - t0) * 1000.0)
    return samples


def time_binary(transport, op, addr, length, iters):
    from pippin_mcp import PippinClient
    client = PippinClient(transport)
    samples = []
    for _ in range(iters):
        t0 = time.monotonic()
        if op == "status":
            client.status()
        else:
            client.read_memory(addr, length)
        samples.append((time.monotonic() - t0) * 1000.0)
    return samples


def _resident_sizes():
    """Best-effort resident-handler sizes for the size comparison."""
    root = os.path.join(os.path.dirname(__file__), "..", "src")
    out = {}
    for name in ("MAINRES.BIN", "LCROM.BIN", "MAINRES-PIP.BIN"):
        p = os.path.join(root, name)
        if os.path.exists(p):
            out[name] = os.path.getsize(p)
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description="Benchmark fast (binary) vs JSON round-trips.")
    p.add_argument("--protocol", choices=["binary", "json"], required=True)
    p.add_argument("--op", choices=["status", "read"], default="status")
    p.add_argument("--addr", type=int, default=1024)
    p.add_argument("--len", dest="length", type=int, default=16)
    p.add_argument("--iters", type=int, default=30)
    p.add_argument("--transport", choices=["tcp", "serial"], default="tcp")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--device", default=None)
    p.add_argument("--baud", type=int, default=9600)
    args = p.parse_args(argv)

    sizes = _resident_sizes()
    json_resident = sizes.get("MAINRES.BIN", 0) + sizes.get("LCROM.BIN", 0)
    fast_resident = sizes.get("MAINRES-PIP.BIN", 0)
    print(f"resident handler sizes: JSON = {json_resident} B "
          f"(MAINRES {sizes.get('MAINRES.BIN','?')} + LCROM {sizes.get('LCROM.BIN','?')}), "
          f"FAST = {fast_resident} B (MAIN_RES only, no LC image)")

    t = _make_transport(args)
    try:
        runner = time_binary if args.protocol == "binary" else time_json
        samples = runner(t, args.op, args.addr, args.length, args.iters)
    finally:
        t.close()

    print(f"{args.protocol} {args.op} x{args.iters}: "
          f"median={statistics.median(samples):.1f} ms  "
          f"min={min(samples):.1f}  max={max(samples):.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
