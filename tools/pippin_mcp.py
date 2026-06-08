"""pippin_mcp.py -- PIP MCP front-end (FastMCP, stdio).

Answers initialize/tools_list/notifications itself; only tool executions hit
the wire as binary frames. One request in flight (async lock). See
docs/DESIGN.md (PIP binary protocol).
"""
import argparse
import asyncio
import time

from pippin_protocol import (
    encode_request, decode_response, BadChecksum, ShortFrame, SYNC,
    OP_PING, OP_STATUS, OP_READ, OP_WRITE, OP_SENDKEY,
    ST_OK, ST_BAD_CK, ST_MESSAGES,
)

MAX_RETRIES = 3
RESP_TIMEOUT = 5.0       # seconds per attempt; a dead link costs up to
#                          MAX_RETRIES * RESP_TIMEOUT (~15 s) before erroring


class McpToolError(Exception):
    """Raised for host-side validation or Apple-reported (ST!=OK) failures."""


# Machine-type codes reported in status's m= field. Mirrors the MACH_* enum in
# src/equates-common.s. Code 5 (unenhanced //e) is only ever reported by the
# NMOS-6502 build (PIP.6502 / PIPPIN.6502); the 65C02 build rejects that machine.
MACHINE_NAMES = {
    0: "unknown",
    1: "//e enhanced",
    2: "//c",
    3: "//c+",
    4: "IIgs",
    5: "unenhanced //e",
}


def _read_response_frame(transport, total_timeout=RESP_TIMEOUT) -> bytes:
    """Hunt for A5, then read ST,RLEN, RLEN payload bytes, CK. Mirrors
    serial_send.read_result_frame but length-framed.

    Locks onto the FIRST A5 in the stream. A stray A5 (line noise) ahead of the
    real frame yields a misaligned slice whose CK fails in decode_response, so
    exchange() retransmits and resyncs. We deliberately do NOT re-hunt past a
    bad A5 here: within one response there is exactly one frame, so "decode
    failed -> retransmit" is the correct, simplest recovery. Re-hunting would
    conflate a stray byte with a genuinely corrupted frame and could skip the
    retransmit a non-idempotent SENDKEY relies on."""
    raw = b""
    deadline = time.monotonic() + total_timeout
    while time.monotonic() < deadline:
        chunk = transport.read_chunk(256, timeout=0.5)
        if chunk:
            raw += chunk
        i = raw.find(bytes([SYNC]))
        if i != -1 and len(raw) >= i + 3:
            rlen = raw[i + 2]
            if len(raw) >= i + 4 + rlen:
                return raw[i:i + 4 + rlen]
    raise ShortFrame(f"no complete response frame in {raw.hex()}")


class PippinClient:
    """Synchronous binary exchange with the Apple. Transport is any object with
    write(bytes) / read_chunk(maxn, timeout) / close()."""

    def __init__(self, transport):
        self.t = transport

    def exchange(self, op: int, args: bytes) -> tuple[int, bytes]:
        # Retransmit on a corrupted/absent response or ST=01 (Apple saw a bad
        # request checksum). READ/STATUS/PING/WRITE are idempotent; SENDKEY is
        # NOT -- if the Apple executed it but the response was lost/corrupted, a
        # retransmit injects the key a second time. Rare on a null-modem link,
        # bounded by MAX_RETRIES; a per-request sequence byte would let the
        # Apple dedupe (deferred -- see spec 5.4).
        frame = encode_request(op, args)
        last = None
        for _ in range(MAX_RETRIES):
            self.t.write(frame)
            try:
                raw = _read_response_frame(self.t)
                st, res = decode_response(raw)
            except (BadChecksum, ShortFrame) as e:
                last = e
                continue
            if st == ST_BAD_CK:          # Apple saw a corrupted request -> retransmit
                last = "Apple reported ST=01 (bad request checksum)"
                continue
            return st, res
        raise McpToolError(f"no valid response after {MAX_RETRIES} tries: {last}")

    def _checked(self, op, args):
        st, res = self.exchange(op, args)
        if st != ST_OK:
            raise McpToolError(ST_MESSAGES.get(st, f"Apple error ST={st}"))
        return res

    # --- tool cores (host-side validation, then wire) ---
    def status(self) -> str:
        b = self._checked(OP_STATUS, b"")
        mach = MACHINE_NAMES.get(b[2], f"unknown (${b[2]:02X})")
        return (f"PIP {b[0]}.{b[1]} m={b[2]} ({mach}) "
                f"wr=${b[3]:02X} rd=${b[4]:02X} key=${b[5]:02X}")

    def read_memory(self, address: int, length: int) -> str:
        if not (0 <= address <= 0xFFFF):
            raise McpToolError("address out of 0..65535")
        if not (1 <= length <= 255):
            raise McpToolError("length out of 1..255")
        res = self._checked(OP_READ, bytes([address & 0xFF, address >> 8, length]))
        return res.hex()

    def write_memory(self, address: int, data_hex: str) -> str:
        if not (0 <= address <= 0xFFFF):
            raise McpToolError("address out of 0..65535")
        try:
            data = bytes.fromhex(data_hex)
        except ValueError:
            raise McpToolError("data_hex must be even-length hex")
        if not (1 <= len(data) <= 128):
            raise McpToolError("data must be 1..128 bytes")
        self._checked(OP_WRITE, bytes([address & 0xFF, address >> 8]) + data)
        return "OK"

    def send_keystroke(self, key: int) -> str:
        if not (0 <= key <= 127):
            raise McpToolError("key out of 0..127")
        self._checked(OP_SENDKEY, bytes([key]))
        return "OK"

    def ping(self) -> bool:
        st, _ = self.exchange(OP_PING, b"")
        return st == ST_OK


def _make_transport(args):
    from transport import TcpTransport, SerialTransport
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


def build_server(client: PippinClient):
    from mcp.server.fastmcp import FastMCP
    mcp = FastMCP("pip")
    lock = asyncio.Lock()

    async def guarded(fn, *a):
        async with lock:                      # one request in flight
            return await asyncio.to_thread(fn, *a)

    @mcp.tool()
    async def status() -> str:
        """PIP status (version, machine, ring indices)."""
        return await guarded(client.status)

    @mcp.tool()
    async def read_memory(address: int, length: int) -> str:
        """Read `length` (1..255) bytes from Apple memory at `address`
        (0..65535). Returns lowercase hex. Rejects $C000-$CFFF."""
        return await guarded(client.read_memory, address, length)

    @mcp.tool()
    async def write_memory(address: int, data_hex: str) -> str:
        """Write hex-encoded bytes (1..128 bytes, even-length hex) to Apple
        memory at `address`. Rejects $C000-$CFFF and $BF00-$BFFF."""
        return await guarded(client.write_memory, address, data_hex)

    @mcp.tool()
    async def send_keystroke(key: int) -> str:
        """Queue a keystroke (key code 0..127) for the next foreground read.

        Not idempotent: on a timeout/transport error the key may or may not
        already be queued on the Apple, and a retransmit can double it (rare --
        serial corruption only)."""
        return await guarded(client.send_keystroke, key)

    return mcp


def main(argv=None):
    p = argparse.ArgumentParser(description="PIP MCP front-end")
    p.add_argument("--transport", choices=["tcp", "serial"], default="tcp")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=1977)
    p.add_argument("--device", default=None)
    p.add_argument("--baud", type=int, default=9600)
    args = p.parse_args(argv)
    client = PippinClient(_make_transport(args))
    try:
        build_server(client).run()      # stdio transport (runs until EOF)
    finally:
        client.t.close()


if __name__ == "__main__":
    main()
